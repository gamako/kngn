//! A harness no-op stub for wasm32-freestanding
//!
//! Keeps the real harness (env, sockets, threads, the filesystem, png) out of the wasm analysis. The public
//! surface is a no-op covering, by an exhaustive grep, every real reference made through `core/platform.zig`,
//! `core/audio.zig` and kit. command and action_registry are std-only, so the real ones are reused; copilot and
//! netsync are no-op namespaces. There is no dependency on png or capture_synthetic (the build does not link them either).

const std = @import("std");
const types = @import("platform_types");

pub const Event = types.Event;
pub const EventStats = types.EventStats;
pub const GamepadState = types.GamepadState;
pub const CompositionSnapshot = types.CompositionSnapshot;

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

pub const InputBlocker = *const fn (ctx: *anyopaque, event: Event) ?[]const u8;

pub const Probe = struct {
    name: []const u8,
    ctx: *anyopaque,
    ext: []const u8 = "bin",
    snapshot: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 = null,
    digest: ?*const fn (ctx: *anyopaque, buf: []u8) []const u8 = null,
    desc: []const u8 = "",
    args: ?[]const ArgSpec = null,
    input_blocker: ?InputBlocker = null,
};

pub fn isEnabled() bool {
    return false;
}

pub fn isManualClock() bool {
    return false;
}

pub fn isHeadlessActive() bool {
    return false;
}

pub fn setHeadlessActive(_: bool) void {}

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

pub fn pollGateFreeRun(native_continue: bool) bool {
    return native_continue;
}

pub fn nextInjectedEvent() ?Event {
    return null;
}

/// Empty composition when the harness is disabled (matches native disabled behaviour).
pub fn getCompositionSnapshot(buf: []u8) CompositionSnapshot {
    return .{
        .text = buf[0..0],
        .revision = 0,
        .cursor = 0,
    };
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

pub fn registerProbe(_: Probe) void {}

pub fn findProbe(_: []const u8) ?*Probe {
    return null;
}

// ============================================================================
// A copilot no-op namespace (only the surface platform.zig touches)
// ============================================================================

pub const copilot = struct {
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
};

// ============================================================================
// A netsync no-op namespace (only the surface platform.zig touches)
// ============================================================================

pub const netsync = struct {
    pub const ActorKind = enum {
        human,
        agent,
    };

    pub const PeerOriginView = struct {
        peer_id: u32,
        kind: ActorKind,
        label: []const u8,
        active: bool,
    };

    pub const StateSync = struct {
        ctx: *anyopaque,
        export_fn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8,
        import_fn: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void,
    };

    pub const PostApplyContext = struct {
        name: []const u8,
        args: []const u8,
        origin_peer: u32,
        seq: u64,
    };
    pub const PostApplyHook = *const fn (ctx: *anyopaque, applied: PostApplyContext) void;

    pub const SessionStateCallback = *const fn (active: bool) void;

    pub const PENDING_CAP: usize = 64;

    pub fn setSessionStateCallback(_: ?SessionStateCallback) void {}
    pub fn initFromEnv() void {}
    pub fn shutdown() void {}
    pub fn pump() void {}
    pub fn isEnabled() bool {
        return false;
    }
    pub fn isHost() bool {
        return false;
    }
    pub fn registerStateSync(_: StateSync) void {}
    pub fn setSharedExecutor(_: ?*command.Executor) void {}
    pub fn forgetSharedExecutor() void {}
    pub fn setPostApplyHook(_: ?*anyopaque, _: ?PostApplyHook) void {}

    pub fn pendingProposalCount() usize {
        return 0;
    }
    pub fn peerCount() usize {
        return 0;
    }
    pub fn localPeerId() u32 {
        return 0;
    }
    pub fn peerMetadataRevision() u64 {
        return 0;
    }
    pub fn resolvePeerOrigin(_: u32, _: []u8) ?PeerOriginView {
        return null;
    }
    pub fn commitAndBroadcast(_: []const u8, _: []const u8, _: []u8) anyerror![]const u8 {
        return error.NotHost;
    }

    pub fn probeDigest(_: *anyopaque, buf: []u8) []const u8 {
        return buf[0..0];
    }

    pub fn probeSnapshot(_: *anyopaque, _: std.mem.Allocator) anyerror![]u8 {
        return error.OutOfMemory;
    }
};
