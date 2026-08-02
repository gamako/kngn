//! A no-op `netsync` for wasm32.
//!
//! Networked concurrent editing needs a TCP transport and a worker thread, neither of which a
//! wasm module has. This module keeps the shape of the surface that `core/platform.zig`, `kit` and
//! the applications reference — by an exhaustive grep of those call sites — so that a wasm build
//! links, and reports "no session" for every query. Any host that wants concurrent editing in a
//! browser needs a transport of its own; this is not a partial implementation of one.

const std = @import("std");

pub const command = @import("command.zig");

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

/// Grouping brackets a run of actions into one undo unit **on the wire**, so with no session
/// there is nothing to group and both ends are no-ops — the same behaviour the native module
/// has outside a session.
pub fn beginActionGroup() void {}
pub fn endActionGroup() void {}

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
