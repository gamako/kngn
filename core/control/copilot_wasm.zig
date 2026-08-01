//! A no-op `copilot` for wasm32.
//!
//! The copilot transport is a loopback TCP server driven by a raw socket API that a wasm module
//! does not have. This module keeps the shape of the surface `core/platform.zig` references — by
//! an exhaustive grep of those call sites — so that a wasm build links, and reports the transport
//! as disabled. The browser control plane is the harness host bridge instead (see
//! `docs/harness.md`).

const command = @import("command.zig");

pub fn parseConfig() void {}
pub fn startTransport() void {}
pub fn stopTransport() void {}
pub fn pump() void {}
pub fn setSharedExecutor(_: ?*command.Executor) void {}
pub fn forgetSharedExecutor() void {}
pub fn setNetsyncSessionActive(_: bool) void {}
pub fn isEnabled() bool {
    return false;
}
