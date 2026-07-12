//! harness no-op stub for wasm32-freestanding（TASK-73.1）
//!
//! 本番 harness（env/socket/thread/fs/png）を wasm 解析から外す。公開面は
//! `core/platform.zig` / `core/audio.zig` / kit 経由の実参照を grep 網羅した no-op。
//! command / action_registry は std のみなので実体を再利用。copilot / netsync は no-op namespace。
//! png / capture_synthetic には依存しない（build 側も link しない）。

const std = @import("std");
const types = @import("platform_types");

pub const Event = types.Event;
pub const EventStats = types.EventStats;
pub const GamepadState = types.GamepadState;

pub const command = @import("command.zig");
pub const action_registry = @import("action_registry.zig");

pub const DIGEST_BUF_LEN = 1024;

pub const ArgSpec = action_registry.ArgSpec;
pub const Action = action_registry.Action;
pub const NetworkPolicy = action_registry.NetworkPolicy;
pub const registerAction = action_registry.registerAction;
pub const findAction = action_registry.findAction;
pub const setActionErrorDetail = action_registry.setActionErrorDetail;

pub const NativePump = struct {
    ptr: *anyopaque = undefined,
    pollFn: *const fn (*anyopaque) bool = undefined,

    pub fn poll(self: NativePump) bool {
        return self.pollFn(self.ptr);
    }
};

pub const Probe = struct {
    name: []const u8,
    ctx: *anyopaque,
    ext: []const u8 = "bin",
    snapshot: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 = null,
    digest: ?*const fn (ctx: *anyopaque, buf: []u8) []const u8 = null,
    desc: []const u8 = "",
    args: ?[]const ArgSpec = null,
};

pub fn isEnabled() bool {
    return false;
}

pub fn isHeadlessActive() bool {
    return false;
}

pub fn isCaptureSyntheticActive() bool {
    return false;
}

pub fn setExternalRegistryEnabled(_: bool) void {}

pub fn parseConfig() void {}

pub fn startTransport() void {}

pub fn pollGate(native_continue: bool) bool {
    return native_continue;
}

pub fn pollGateWithPump(native_continue: bool, _: ?NativePump) bool {
    return native_continue;
}

pub fn nextInjectedEvent() ?Event {
    return null;
}

pub fn filterNativeEvent(ev: Event) ?Event {
    return ev;
}

pub fn getGamepadState(_: u8) ?GamepadState {
    return null;
}

pub fn onLock(_: []const u32, _: u32, _: u32) void {}

pub fn onLockMiss() void {}

pub fn onStats(_: EventStats) void {}

pub fn onPresent() void {}

pub fn now() f64 {
    return 0;
}

pub fn onAudioSamples(_: []const f32, _: u32, _: u32, _: u32) void {}

pub const HeadlessFramebufferView = struct { pixels: []u32, width: u32, height: u32 };

pub fn createHeadlessWindow(_: u32, _: u32) std.mem.Allocator.Error!void {
    return error.OutOfMemory;
}

pub fn headlessLock() HeadlessFramebufferView {
    return .{ .pixels = &.{}, .width = 0, .height = 0 };
}

pub fn destroyHeadlessWindow() void {}

pub fn registerProbe(_: Probe) void {}

pub fn findProbe(_: []const u8) ?*Probe {
    return null;
}

// ============================================================================
// copilot no-op namespace（platform.zig が触る面のみ）
// ============================================================================

pub const copilot = struct {
    pub fn parseConfig() void {}
    pub fn startTransport() void {}
    pub fn stopTransport() void {}
    pub fn pump() void {}
    pub fn setSharedExecutor(_: ?*command.Executor) void {}
    pub fn setNetsyncSessionActive(_: bool) void {}
    pub fn isEnabled() bool {
        return false;
    }
};

// ============================================================================
// netsync no-op namespace（platform.zig が触る面のみ）
// ============================================================================

pub const netsync = struct {
    pub const StateSync = struct {
        ctx: *anyopaque,
        export_fn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8,
        import_fn: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void,
    };

    pub const SessionStateCallback = *const fn (active: bool) void;

    pub fn setSessionStateCallback(_: ?SessionStateCallback) void {}
    pub fn initFromEnv() void {}
    pub fn shutdown() void {}
    pub fn pump() void {}
    pub fn isEnabled() bool {
        return false;
    }
    pub fn registerStateSync(_: StateSync) void {}
    pub fn setSharedExecutor(_: ?*command.Executor) void {}

    pub fn probeDigest(_: *anyopaque, buf: []u8) []const u8 {
        return buf[0..0];
    }

    pub fn probeSnapshot(_: *anyopaque, _: std.mem.Allocator) anyerror![]u8 {
        return error.OutOfMemory;
    }
};
