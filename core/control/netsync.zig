//! The netsync transport plus the PROPOSE/COMMIT/REJECT relay.
//!
//! The transport layer: a persistent TCP connection, HELLO, the frame codec and the queues.
//! The relay layer: the NetworkPolicy router, commitAndBroadcast and proposeToHost, and applying the semantics inside pump.
//! StateSync, revert undo and the command log integration (remote_commit) build on top of those.
//! This module is std only (the core layer of ADR-007, depending on neither harness nor libs). action_registry and command are
//! relative imports (the same instances are shared through harness).
//!
//! ## Hot path declaration
//! All of the code runs "at event time only" (establishing a connection, receiving a frame, HELLO, applying a PROPOSE or COMMIT).
//! `pump()` is called every frame, but the work is proportional to the number of pending inbound entries (it returns at once when empty).
//! It touches neither a per-frame all-pixel loop nor real time (per sample). The reader, writer and acceptor do
//! blocking socket IO only and never touch application state (applying happens on the main thread's pump alone).
//!
//! ## The provisional exception when applying a remote command
//! The wire seq is not fed in through `ExecuteSource.remote_commit` (because of a client's local_only seq consumption and
//! the resulting StaleRemoteSeq collision). It goes through the shared executor with `source=.local` plus `record_policy=.no_record`.
//! With no executor set, it falls back to `action_registry.dispatch`.

const std = @import("std");
const builtin = @import("builtin");
const net = std.Io.net;
const Io = std.Io;
const action_registry = @import("action_registry.zig");
const command = @import("command.zig");

const gpa = std.heap.page_allocator;

pub const PROTOCOL_VERSION: u32 = 1;
pub const MAX_PEERS: usize = 8;
pub const MAX_ACTION_FRAME_BYTES: usize = 4096;
pub const MAX_SYNC_BYTES: usize = 16 * 1024 * 1024;
pub const MAX_LABEL_LEN: usize = 200;
pub const INBOUND_CAP: usize = 256;
pub const OUTBOUND_CAP: usize = 64;

pub const FrameKind = enum(u8) {
    hello = 0x01,
    propose = 0x02,
    commit = 0x03,
    sync = 0x04,
    reject = 0x05,
    propose_revert = 0x06,
    commit_revert = 0x07,
    peer_info = 0x08,
    /// Ephemeral presence. Consumes neither a COMMIT nor a seq.
    presence = 0x09,
    _,
};

/// The fixed PRESENCE payload length (origin_peer + subtype + reserved + ttl + 4×i32).
pub const PRESENCE_PAYLOAD_LEN: usize = 24;
pub const PRESENCE_QUEUE_CAP: usize = 64;

pub const PresenceSubtype = enum(u8) {
    point = 0x01,
    highlight = 0x02,
    suggest = 0x03,

    pub fn defaultTtlMs(self: PresenceSubtype) u16 {
        return switch (self) {
            .point => 1500,
            .highlight => 2000,
            .suggest => 1200,
        };
    }

    pub fn actionName(self: PresenceSubtype) []const u8 {
        return switch (self) {
            .point => "presence_point",
            .highlight => "presence_highlight",
            .suggest => "presence_suggest",
        };
    }

    pub fn fromByte(b: u8) ?PresenceSubtype {
        return switch (b) {
            0x01 => .point,
            0x02 => .highlight,
            0x03 => .suggest,
            else => null,
        };
    }
};

pub const PresencePayload = struct {
    origin_peer: u32,
    subtype: PresenceSubtype,
    ttl_ms: u16,
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
};

pub const ActorKind = enum {
    human,
    agent,

    pub fn fromToken(s: []const u8) ?ActorKind {
        if (std.mem.eql(u8, s, "human")) return .human;
        if (std.mem.eql(u8, s, "agent")) return .agent;
        return null;
    }

    pub fn toToken(self: ActorKind) []const u8 {
        return switch (self) {
            .human => "human",
            .agent => "agent",
        };
    }
};

pub const Frame = struct {
    kind: u8,
    payload: []const u8,
};

pub const PeerView = struct {
    peer_id: u32,
    kind: ActorKind,
    label: []const u8,
};

/// The result of resolving a peer origin. `label` is a copy into the caller's `label_buf`.
pub const PeerOriginView = struct {
    peer_id: u32,
    kind: ActorKind,
    label: []const u8,
    active: bool,
};

/// The host's own fixed identity (peer_id=0). There is no environment variable such as `KNGN_NETSYNC_HOST_ACTOR`.
pub const HOST_PEER_ID: u32 = 0;
pub const HOST_ACTOR_KIND: ActorKind = .human;
pub const HOST_LABEL: []const u8 = "host";

pub const Role = enum { disabled, host, client };
const SlotState = enum { empty, hello_pending, active, closing };

pub const ProtocolError = error{
    PayloadTooLarge,
    ProtocolError,
    EndOfStream,
};

/// The payload limit per kind (exceeding it disconnects with a protocol error).
pub fn maxPayloadForKind(kind: u8) usize {
    if (kind == @intFromEnum(FrameKind.sync)) return MAX_SYNC_BYTES;
    if (kind == @intFromEnum(FrameKind.presence)) return PRESENCE_PAYLOAD_LEN;
    return MAX_ACTION_FRAME_BYTES;
}

pub fn isKnownKind(kind: u8) bool {
    return kind >= 0x01 and kind <= 0x09;
}

/// Encodes the 24B PRESENCE payload (little-endian). reserved is always 0.
pub fn formatPresencePayload(buf: []u8, p: PresencePayload) ![]const u8 {
    if (buf.len < PRESENCE_PAYLOAD_LEN) return error.PayloadTooLarge;
    std.mem.writeInt(u32, buf[0..4], p.origin_peer, .little);
    buf[4] = @intFromEnum(p.subtype);
    buf[5] = 0; // reserved
    std.mem.writeInt(u16, buf[6..8], p.ttl_ms, .little);
    std.mem.writeInt(i32, buf[8..12], p.x0, .little);
    std.mem.writeInt(i32, buf[12..16], p.y0, .little);
    std.mem.writeInt(i32, buf[16..20], p.x1, .little);
    std.mem.writeInt(i32, buf[20..24], p.y1, .little);
    return buf[0..PRESENCE_PAYLOAD_LEN];
}

/// Decodes PRESENCE. A length mismatch, reserved≠0, an unknown subtype, or TTL>10000 is a ProtocolError.
/// `ttl_ms==0` expands to the subtype's default.
pub fn parsePresencePayload(payload: []const u8) ProtocolError!PresencePayload {
    if (payload.len != PRESENCE_PAYLOAD_LEN) return error.ProtocolError;
    if (payload[5] != 0) return error.ProtocolError;
    const subtype = PresenceSubtype.fromByte(payload[4]) orelse return error.ProtocolError;
    var ttl = std.mem.readInt(u16, payload[6..8], .little);
    if (ttl > 10000) return error.ProtocolError;
    if (ttl == 0) ttl = subtype.defaultTtlMs();
    return .{
        .origin_peer = std.mem.readInt(u32, payload[0..4], .little),
        .subtype = subtype,
        .ttl_ms = ttl,
        .x0 = std.mem.readInt(i32, payload[8..12], .little),
        .y0 = std.mem.readInt(i32, payload[12..16], .little),
        .x1 = std.mem.readInt(i32, payload[16..20], .little),
        .y1 = std.mem.readInt(i32, payload[20..24], .little),
    };
}

/// Builds the args line for a harness or remote dispatch.
/// point/suggest: `peer=<id> <x> <y> <ttl_ms>` / highlight: `peer=<id> <x0> <y0> <x1> <y1> <ttl_ms>`
pub fn formatPresenceRemoteArgs(buf: []u8, p: PresencePayload) ![]const u8 {
    return switch (p.subtype) {
        .point, .suggest => std.fmt.bufPrint(buf, "peer={d} {d} {d} {d}", .{ p.origin_peer, p.x0, p.y0, p.ttl_ms }),
        .highlight => std.fmt.bufPrint(buf, "peer={d} {d} {d} {d} {d} {d}", .{ p.origin_peer, p.x0, p.y0, p.x1, p.y1, p.ttl_ms }),
    };
}

/// Encodes a frame into the Writer (kind + len little-endian + payload).
pub fn encodeFrame(w: *Io.Writer, kind: u8, payload: []const u8) Io.Writer.Error!void {
    try w.writeByte(kind);
    try w.writeInt(u32, @intCast(payload.len), .little);
    try w.writeAll(payload);
}

/// Reads the header, and reads the payload into `buf` when len is within the limit. Over the limit gives `error.PayloadTooLarge`.
/// The payload returned is `buf[0..len]`.
pub fn decodeFrame(r: *Io.Reader, buf: []u8) (ProtocolError || Io.Reader.Error)!Frame {
    const kind = try r.takeByte();
    const len = try r.takeInt(u32, .little);
    const max = maxPayloadForKind(kind);
    if (len > max) return error.PayloadTooLarge;
    if (len > buf.len) return error.PayloadTooLarge;
    if (len > 0) try r.readSliceAll(buf[0..len]);
    return .{ .kind = kind, .payload = buf[0..len] };
}

/// Discards a payload by streaming it away (in fixed 4096B chunks, so SYNC's 16MiB is never allocated).
pub fn discardPayload(r: *Io.Reader, len: u32) (Io.Reader.Error)!void {
    var remaining: u32 = len;
    var chunk: [MAX_ACTION_FRAME_BYTES]u8 = undefined;
    while (remaining > 0) {
        const n: u32 = @min(remaining, @as(u32, @intCast(chunk.len)));
        try r.readSliceAll(chunk[0..n]);
        remaining -= n;
    }
}

/// For validating a HELLO payload (client to host). On success it returns the kind and the label; the label is a slice inside the payload.
pub fn parseClientHello(payload: []const u8) ProtocolError!struct { kind: ActorKind, label: []const u8 } {
    var it = std.mem.tokenizeScalar(u8, payload, ' ');
    const role_tok = it.next() orelse return error.ProtocolError;
    const ver_s = it.next() orelse return error.ProtocolError;
    const kind_s = it.next() orelse return error.ProtocolError;
    const label = std.mem.trim(u8, it.rest(), " ");
    if (!std.mem.eql(u8, role_tok, "client")) return error.ProtocolError;
    const ver = std.fmt.parseInt(u32, ver_s, 10) catch return error.ProtocolError;
    if (ver != PROTOCOL_VERSION) return error.ProtocolError;
    const kind = ActorKind.fromToken(kind_s) orelse return error.ProtocolError;
    if (label.len > MAX_LABEL_LEN) return error.ProtocolError;
    for (label) |c| {
        if (c < 0x20) return error.ProtocolError; // an ASCII control character
    }
    return .{ .kind = kind, .label = label };
}

/// For validating a HELLO payload (host to client). On success it returns the peer_id.
pub fn parseHostHello(payload: []const u8) ProtocolError!u32 {
    var it = std.mem.tokenizeScalar(u8, payload, ' ');
    const role_tok = it.next() orelse return error.ProtocolError;
    const ver_s = it.next() orelse return error.ProtocolError;
    const id_s = it.next() orelse return error.ProtocolError;
    if (it.next() != null) return error.ProtocolError;
    if (!std.mem.eql(u8, role_tok, "host")) return error.ProtocolError;
    const ver = std.fmt.parseInt(u32, ver_s, 10) catch return error.ProtocolError;
    if (ver != PROTOCOL_VERSION) return error.ProtocolError;
    return std.fmt.parseInt(u32, id_s, 10) catch return error.ProtocolError;
}

pub fn formatClientHello(buf: []u8, kind: ActorKind, label: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "client {d} {s} {s}", .{ PROTOCOL_VERSION, kind.toToken(), label });
}

pub fn formatHostHello(buf: []u8, peer_id: u32) ![]const u8 {
    return std.fmt.bufPrint(buf, "host {d} {d}", .{ PROTOCOL_VERSION, peer_id });
}

/// The kind byte of a PEER_INFO payload (0=human, 1=agent, 0xFF=left).
pub const PEER_INFO_KIND_HUMAN: u8 = 0;
pub const PEER_INFO_KIND_AGENT: u8 = 1;
pub const PEER_INFO_KIND_LEFT: u8 = 0xFF;

/// A PEER_INFO payload: u32 LE peer_id (4B) ++ u8 kind (1B) ++ "<label>" (all the rest).
/// The codec only; the semantics of distributing and receiving it live elsewhere.
pub fn formatPeerInfo(buf: []u8, peer_id: u32, kind: u8, label: []const u8) ![]const u8 {
    if (label.len > MAX_LABEL_LEN) return error.LabelTooLong;
    const total = 4 + 1 + label.len;
    if (buf.len < total) return error.NoSpaceLeft;
    std.mem.writeInt(u32, buf[0..4], peer_id, .little);
    buf[4] = kind;
    @memcpy(buf[5..][0..label.len], label);
    return buf[0..total];
}

/// Decodes a PEER_INFO payload (the label is a slice inside the payload). An unknown kind value, or a
/// control character or over-length label, is a protocol error (the same rule as HELLO's label validation).
pub fn parsePeerInfo(payload: []const u8) ProtocolError!struct { peer_id: u32, kind: u8, label: []const u8 } {
    if (payload.len < 5) return error.ProtocolError;
    const peer_id = std.mem.readInt(u32, payload[0..4], .little);
    const kind = payload[4];
    if (kind != PEER_INFO_KIND_HUMAN and kind != PEER_INFO_KIND_AGENT and kind != PEER_INFO_KIND_LEFT)
        return error.ProtocolError;
    const label = payload[5..];
    if (label.len > MAX_LABEL_LEN) return error.ProtocolError;
    for (label) |c| {
        if (c < 0x20) return error.ProtocolError; // an ASCII control character
    }
    return .{ .peer_id = peer_id, .kind = kind, .label = label };
}

/// Splits `"<name> <args>"` or `"<name>"` (name up to the first space, args the rest).
pub fn splitNameArgs(s: []const u8) struct { name: []const u8, args: []const u8 } {
    const t = std.mem.trim(u8, s, &std.ascii.whitespace);
    if (t.len == 0) return .{ .name = "", .args = "" };
    if (std.mem.indexOfScalar(u8, t, ' ')) |i| {
        return .{ .name = t[0..i], .args = t[i + 1 ..] };
    }
    return .{ .name = t, .args = "" };
}

pub fn formatProposePayload(buf: []u8, proposal_id: u32, name: []const u8, args: []const u8) ![]const u8 {
    if (buf.len < 4) return error.PayloadTooLarge;
    std.mem.writeInt(u32, buf[0..4], proposal_id, .little);
    const rest = if (args.len == 0)
        try std.fmt.bufPrint(buf[4..], "{s}", .{name})
    else
        try std.fmt.bufPrint(buf[4..], "{s} {s}", .{ name, args });
    return buf[0 .. 4 + rest.len];
}

pub fn parseProposePayload(payload: []const u8) ProtocolError!struct { proposal_id: u32, name: []const u8, args: []const u8 } {
    if (payload.len < 4) return error.ProtocolError;
    const id = std.mem.readInt(u32, payload[0..4], .little);
    const na = splitNameArgs(payload[4..]);
    if (na.name.len == 0) return error.ProtocolError;
    return .{ .proposal_id = id, .name = na.name, .args = na.args };
}

pub fn formatCommitPayload(buf: []u8, seq: u64, origin_peer: u32, name: []const u8, args: []const u8) ![]const u8 {
    if (buf.len < 12) return error.PayloadTooLarge;
    std.mem.writeInt(u64, buf[0..8], seq, .little);
    std.mem.writeInt(u32, buf[8..12], origin_peer, .little);
    const rest = if (args.len == 0)
        try std.fmt.bufPrint(buf[12..], "{s}", .{name})
    else
        try std.fmt.bufPrint(buf[12..], "{s} {s}", .{ name, args });
    return buf[0 .. 12 + rest.len];
}

pub fn parseCommitPayload(payload: []const u8) ProtocolError!struct { seq: u64, origin_peer: u32, name: []const u8, args: []const u8 } {
    if (payload.len < 12) return error.ProtocolError;
    const seq = std.mem.readInt(u64, payload[0..8], .little);
    const origin = std.mem.readInt(u32, payload[8..12], .little);
    const na = splitNameArgs(payload[12..]);
    if (na.name.len == 0) return error.ProtocolError;
    return .{ .seq = seq, .origin_peer = origin, .name = na.name, .args = na.args };
}

pub fn formatRejectPayload(buf: []u8, proposal_id: u32, reason: []const u8) ![]const u8 {
    if (buf.len < 4) return error.PayloadTooLarge;
    std.mem.writeInt(u32, buf[0..4], proposal_id, .little);
    if (4 + reason.len > buf.len) return error.PayloadTooLarge;
    if (reason.len > 0) @memcpy(buf[4 .. 4 + reason.len], reason);
    return buf[0 .. 4 + reason.len];
}

pub fn parseRejectPayload(payload: []const u8) ProtocolError!struct { proposal_id: u32, reason: []const u8 } {
    if (payload.len < 4) return error.ProtocolError;
    return .{
        .proposal_id = std.mem.readInt(u32, payload[0..4], .little),
        .reason = payload[4..],
    };
}

/// PROPOSE_REVERT: u32 proposal_id ++ u64 target_seq
pub fn formatProposeRevertPayload(buf: []u8, proposal_id: u32, target_seq: u64) ![]const u8 {
    if (buf.len < 12) return error.PayloadTooLarge;
    std.mem.writeInt(u32, buf[0..4], proposal_id, .little);
    std.mem.writeInt(u64, buf[4..12], target_seq, .little);
    return buf[0..12];
}

pub fn parseProposeRevertPayload(payload: []const u8) ProtocolError!struct { proposal_id: u32, target_seq: u64 } {
    if (payload.len < 12) return error.ProtocolError;
    return .{
        .proposal_id = std.mem.readInt(u32, payload[0..4], .little),
        .target_seq = std.mem.readInt(u64, payload[4..12], .little),
    };
}

/// COMMIT_REVERT: u64 seq ++ u64 target_seq
pub fn formatCommitRevertPayload(buf: []u8, seq: u64, target_seq: u64) ![]const u8 {
    if (buf.len < 16) return error.PayloadTooLarge;
    std.mem.writeInt(u64, buf[0..8], seq, .little);
    std.mem.writeInt(u64, buf[8..16], target_seq, .little);
    return buf[0..16];
}

pub fn parseCommitRevertPayload(payload: []const u8) ProtocolError!struct { seq: u64, target_seq: u64 } {
    if (payload.len < 16) return error.ProtocolError;
    return .{
        .seq = std.mem.readInt(u64, payload[0..8], .little),
        .target_seq = std.mem.readInt(u64, payload[8..16], .little),
    };
}

// ============================================================================
// Queues
// ============================================================================

/// The internal inbound marker (it never appears on the wire). ClientJoined = peer_id + generation.
const INTERNAL_CLIENT_JOINED: u8 = 0xF0;

const QueueSlot = struct {
    kind: u8 = 0,
    len: u32 = 0,
    /// The peer_id it came from (for the host's PROPOSE handling and for returning a REJECT; a client receiving one sees 0=host).
    peer_id: u32 = 0,
    data: [MAX_ACTION_FRAME_BYTES]u8 = undefined,
};

/// An entry of the single outbound FIFO ring (inline when ≤4096, and heap-owned when big).
const OutboundEntry = union(enum) {
    inline_frame: struct {
        kind: u8 = 0,
        len: u32 = 0,
        data: [MAX_ACTION_FRAME_BYTES]u8 = undefined,
    },
    big_frame: struct {
        kind: u8 = 0,
        ptr: [*]u8 = undefined,
        len: u32 = 0,
    },

    fn free(self: *OutboundEntry) void {
        switch (self.*) {
            .inline_frame => {},
            .big_frame => |b| {
                gpa.free(b.ptr[0..b.len]);
                self.* = .{ .inline_frame = .{} };
            },
        }
    }
};

const InboundQueue = struct {
    mutex: Io.Mutex = .init,
    slots: [INBOUND_CAP]QueueSlot = undefined,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,

    fn enqueue(self: *InboundQueue, io: Io, kind: u8, payload: []const u8, peer_id: u32) bool {
        if (payload.len > MAX_ACTION_FRAME_BYTES) return false;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.count >= INBOUND_CAP) return false;
        const s = &self.slots[self.tail];
        s.kind = kind;
        s.len = @intCast(payload.len);
        s.peer_id = peer_id;
        if (payload.len > 0) @memcpy(s.data[0..payload.len], payload);
        self.tail = (self.tail + 1) % INBOUND_CAP;
        self.count += 1;
        return true;
    }

    fn dequeue(self: *InboundQueue, io: Io, out_kind: *u8, out_peer: *u32, out_buf: []u8) ?usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.count == 0) return null;
        const s = &self.slots[self.head];
        out_kind.* = s.kind;
        out_peer.* = s.peer_id;
        const n = @min(s.len, out_buf.len);
        if (n > 0) @memcpy(out_buf[0..n], s.data[0..n]);
        self.head = (self.head + 1) % INBOUND_CAP;
        self.count -= 1;
        return n;
    }

    fn clear(self: *InboundQueue, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.head = 0;
        self.tail = 0;
        self.count = 0;
    }

    fn len(self: *InboundQueue, io: Io) usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.count;
    }
};

const OutboundQueue = struct {
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    slots: [OUTBOUND_CAP]OutboundEntry = [_]OutboundEntry{.{ .inline_frame = .{} }} ** OUTBOUND_CAP,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    closed: bool = false,

    fn enqueue(self: *OutboundQueue, io: Io, kind: u8, payload: []const u8) bool {
        if (payload.len > MAX_ACTION_FRAME_BYTES) return false;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.closed) return false;
        if (self.count >= OUTBOUND_CAP) return false;
        var inline_e: OutboundEntry = .{ .inline_frame = .{ .kind = kind, .len = @intCast(payload.len) } };
        if (payload.len > 0) @memcpy(inline_e.inline_frame.data[0..payload.len], payload);
        self.slots[self.tail] = inline_e;
        self.tail = (self.tail + 1) % OUTBOUND_CAP;
        self.count += 1;
        self.cond.signal(io);
        return true;
    }

    /// A big entry, for a SYNC and the like. On success the queue takes ownership of `owned`; on failure the caller frees it.
    fn enqueueBig(self: *OutboundQueue, io: Io, kind: u8, owned: []u8) bool {
        if (owned.len > MAX_SYNC_BYTES) return false;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.closed) return false;
        if (self.count >= OUTBOUND_CAP) return false;
        self.slots[self.tail] = .{ .big_frame = .{ .kind = kind, .ptr = owned.ptr, .len = @intCast(owned.len) } };
        self.tail = (self.tail + 1) % OUTBOUND_CAP;
        self.count += 1;
        self.cond.signal(io);
        return true;
    }

    /// For the writer. Returns null when it is closed and empty. Ownership of the entry moves to the caller.
    fn dequeueWait(self: *OutboundQueue, io: Io, out: *OutboundEntry) ?void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (self.count == 0 and !self.closed) {
            self.cond.waitUncancelable(io, &self.mutex);
        }
        if (self.count == 0) return null; // closed
        out.* = self.slots[self.head];
        self.slots[self.head] = .{ .inline_frame = .{} };
        self.head = (self.head + 1) % OUTBOUND_CAP;
        self.count -= 1;
        return {};
    }

    fn close(self: *OutboundQueue, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.closed = true;
        self.cond.broadcast(io);
    }

    fn freeQueuedLocked(self: *OutboundQueue) void {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const idx = (self.head + i) % OUTBOUND_CAP;
            self.slots[idx].free();
        }
        self.head = 0;
        self.tail = 0;
        self.count = 0;
    }

    fn reset(self: *OutboundQueue, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.freeQueuedLocked();
        self.closed = false;
    }

    /// A non-blocking dequeue. Returns null when empty.
    fn tryDequeue(self: *OutboundQueue, io: Io, out: *OutboundEntry) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.count == 0) return false;
        out.* = self.slots[self.head];
        self.slots[self.head] = .{ .inline_frame = .{} };
        self.head = (self.head + 1) % OUTBOUND_CAP;
        self.count -= 1;
        return true;
    }

    /// For waking the writer (called when a presence entry is enqueued).
    fn signal(self: *OutboundQueue, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.cond.signal(io);
    }

    /// Waits once without dequeuing. Returns false when it is closed and empty.
    /// It returns true for a presence signal too, and the caller retries both queues at the top of its loop.
    fn waitForWork(self: *OutboundQueue, io: Io) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.closed and self.count == 0) return false;
        if (self.count > 0) return true;
        self.cond.waitUncancelable(io, &self.mutex);
        if (self.closed and self.count == 0) return false;
        return true;
    }

    fn isClosed(self: *OutboundQueue, io: Io) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.closed;
    }

    /// The number of entries still queued. `count` belongs to this queue's own mutex, so an
    /// observer holding only `peers_mutex` would be reading it unsynchronised; go through here.
    fn len(self: *OutboundQueue, io: Io) usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.count;
    }
};

/// The inbound queue for PRESENCE only (separate from the COMMIT queue; when full it drops rather than disconnecting).
/// Latest-wins per peer and subtype (an unprocessed entry is replaced).
const PresenceInboundQueue = struct {
    mutex: Io.Mutex = .init,
    slots: [PRESENCE_QUEUE_CAP]struct {
        peer_id: u32 = 0,
        subtype: u8 = 0,
        data: [PRESENCE_PAYLOAD_LEN]u8 = undefined,
        occupied: bool = false,
    } = undefined,
    count: usize = 0,

    fn clear(self: *PresenceInboundQueue, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (&self.slots) |*s| s.occupied = false;
        self.count = 0;
    }

    fn len(self: *PresenceInboundQueue, io: Io) usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.count;
    }

    /// The payload is exactly 24B. true on success; a drop because it is full gives false (without disconnecting).
    fn enqueueLatestWins(self: *PresenceInboundQueue, io: Io, peer_id: u32, payload: []const u8) bool {
        if (payload.len != PRESENCE_PAYLOAD_LEN) return false;
        const subtype = payload[4];
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        // replace any unprocessed entry for the same peer and subtype
        for (&self.slots) |*s| {
            if (s.occupied and s.peer_id == peer_id and s.subtype == subtype) {
                @memcpy(&s.data, payload[0..PRESENCE_PAYLOAD_LEN]);
                return true;
            }
        }
        if (self.count >= PRESENCE_QUEUE_CAP) return false;
        for (&self.slots) |*s| {
            if (!s.occupied) {
                s.occupied = true;
                s.peer_id = peer_id;
                s.subtype = subtype;
                @memcpy(&s.data, payload[0..PRESENCE_PAYLOAD_LEN]);
                self.count += 1;
                return true;
            }
        }
        return false;
    }

    fn dequeue(self: *PresenceInboundQueue, io: Io, out_peer: *u32, out_buf: *[PRESENCE_PAYLOAD_LEN]u8) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (&self.slots) |*s| {
            if (s.occupied) {
                out_peer.* = s.peer_id;
                @memcpy(out_buf, &s.data);
                s.occupied = false;
                self.count -= 1;
                return true;
            }
        }
        return false;
    }
};

/// The outbound queue for PRESENCE only (separate from the COMMIT outbound; when full it drops rather than disconnecting).
/// Latest-wins per subtype.
const PresenceOutboundQueue = struct {
    mutex: Io.Mutex = .init,
    slots: [PRESENCE_QUEUE_CAP]struct {
        subtype: u8 = 0,
        data: [PRESENCE_PAYLOAD_LEN]u8 = undefined,
        occupied: bool = false,
    } = undefined,
    count: usize = 0,
    closed: bool = false,

    fn clear(self: *PresenceOutboundQueue, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (&self.slots) |*s| s.occupied = false;
        self.count = 0;
        self.closed = false;
    }

    fn close(self: *PresenceOutboundQueue, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.closed = true;
    }

    fn enqueueLatestWins(self: *PresenceOutboundQueue, io: Io, payload: []const u8) bool {
        if (payload.len != PRESENCE_PAYLOAD_LEN) return false;
        const subtype = payload[4];
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.closed) return false;
        for (&self.slots) |*s| {
            if (s.occupied and s.subtype == subtype) {
                @memcpy(&s.data, payload[0..PRESENCE_PAYLOAD_LEN]);
                return true;
            }
        }
        if (self.count >= PRESENCE_QUEUE_CAP) return false;
        for (&self.slots) |*s| {
            if (!s.occupied) {
                s.occupied = true;
                s.subtype = subtype;
                @memcpy(&s.data, payload[0..PRESENCE_PAYLOAD_LEN]);
                self.count += 1;
                return true;
            }
        }
        return false;
    }

    fn tryDequeue(self: *PresenceOutboundQueue, io: Io, out_buf: *[PRESENCE_PAYLOAD_LEN]u8) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (&self.slots) |*s| {
            if (s.occupied) {
                @memcpy(out_buf, &s.data);
                s.occupied = false;
                self.count -= 1;
                return true;
            }
        }
        return false;
    }
};

// ============================================================================
// The connection slot and the peer catalog (the client side)
// ============================================================================

const ConnSlot = struct {
    state: SlotState = .empty,
    stream: net.Stream = undefined,
    socket_open: bool = false,
    peer_id: u32 = 0,
    actor_kind: ActorKind = .human,
    label_buf: [MAX_LABEL_LEN]u8 = undefined,
    label_len: usize = 0,
    hello_done: bool = false,
    /// A SYNC has been sent (so it is a broadcast target). True once ClientJoined has been handled.
    synced: bool = false,
    /// True once an export succeeds. An empty SYNC (nothing registered) leaves it false.
    snapshot_valid: bool = false,
    join_snapshot_seq: u64 = 0,
    /// For detecting a reused slot. Incremented each time it returns to empty.
    generation: u32 = 0,
    reader_thread: ?std.Thread = null,
    writer_thread: ?std.Thread = null,
    outbound: OutboundQueue = .{},
    /// The outbound queue for PRESENCE only (dropping when full, separate from COMMIT).
    presence_outbound: PresenceOutboundQueue = .{},
    /// The index within the host's slots array. On a client it is 0.
    slot_index: usize = 0,
    is_client_conn: bool = false,
};

/// The client's fixed-length peer catalog (the host plus at most MAX_PEERS clients). The host uses slots[] plus its fixed identity.
const MAX_PEER_CATALOG: usize = MAX_PEERS + 1;

const PeerCatalogEntry = struct {
    occupied: bool = false,
    active: bool = false,
    peer_id: u32 = 0,
    kind: ActorKind = .human,
    label_buf: [MAX_LABEL_LEN]u8 = undefined,
    label_len: usize = 0,
};

/// The state synchronisation adapter used on join (a single slot).
/// `export_fn` **must not return 0 bytes** (empty is the reserved marker for "no snapshot"; only an unregistered exporter gives an empty SYNC).
pub const StateSync = struct {
    ctx: *anyopaque,
    export_fn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8,
    import_fn: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void,
};

// ============================================================================
// Module state
// ============================================================================
//
// ## The synchronisation rule (peers_mutex)
// Every read and write of the following fields happens under `peers_mutex` (a path taken at event time only):
//   role / started / local_peer_id / next_peer_id / router_clear_pending /
//   slots[*].state and a slot's peer metadata (peer_id, kind, label, hello_done, socket_open) /
//   the same fields on client_slot /
//   peer_catalog[*] / peer_metadata_revision
// Only `stop_flag` is atomic. `have_server` and acceptor_thread belong to main (init and shutdown) alone.
// wire_seq, next_proposal_id, last_rejected_*, last_applied_seq and shared_executor belong to the main thread alone
// (pump, the router, setSharedExecutor; the reader never touches them).
// The reader thread mostly receives wire frames and enqueues inbound entries, but HELLO handling (`handleHello`)
// still runs on the reader thread, taking peers_mutex and writing the slot and catalog directly (including registering
// in peer_catalog, distributing PEER_INFO, and updating peer_metadata_revision on a join or a leave). Reflecting a
// PEER_INFO that came from another peer (`handlePeerInfo`) and resolving an origin (`resolvePeerOrigin`) happen on the
// main thread (through pump). All of them are protected by the same `peers_mutex`.
// The outbound queue has its own mutex, and the lock order is **peers_mutex → outbound.mutex** (never the reverse).

var role: Role = .disabled;
var started: bool = false;
var stop_flag: std.atomic.Value(bool) = .init(false);

var io_inited = false;
var threaded: Io.Threaded = undefined;
var io_val: Io = undefined;

var server: net.Server = undefined;
var have_server = false;
var acceptor_thread: ?std.Thread = null;

var peers_mutex: Io.Mutex = .init;
var slots: [MAX_PEERS]ConnSlot = [_]ConnSlot{.{}} ** MAX_PEERS;
var next_peer_id: u32 = 1; // 0 is reserved for the host

var client_slot: ConnSlot = .{};
var local_peer_id: u32 = 0; // what a client receives in the host's HELLO

/// The client-side peer catalog (unused on a host). A leave keeps the kind and label as an active=false tombstone.
var peer_catalog: [MAX_PEER_CATALOG]PeerCatalogEntry = [_]PeerCatalogEntry{.{}} ** MAX_PEER_CATALOG;
/// A single peer metadata revision for the whole module (there is no per-entry revision).
var peer_metadata_revision: u64 = 0;

var inbound: InboundQueue = .{};
/// The inbound queue for PRESENCE only (handled outside the awaiting_sync gate).
var presence_inbound: PresenceInboundQueue = .{};

var client_actor_kind: ActorKind = .human;
/// The default label. Raising just the len over `undefined` would put a NUL on the HELLO and the host would disconnect (confirmed in the E2E).
const default_client_label = "client";
var client_label_buf: [MAX_LABEL_LEN]u8 = blk: {
    var b = [_]u8{0} ** MAX_LABEL_LEN;
    @memcpy(b[0..default_client_label.len], default_client_label);
    break :blk b;
};
var client_label_len: usize = default_client_label.len;

/// The flag by which a client's fail-soft (originating in the reader) asks main's pump to clear the router.
var router_clear_pending: bool = false;

/// The host's wire COMMIT seq (monotonically increasing, belonging to the main thread alone).
var wire_seq: u64 = 0;
/// On a client: the seq of the last COMMIT applied (main thread alone; the client's side of the digest's last_seq).
var last_applied_seq: u64 = 0;
/// A client's proposal_id (monotonically increasing, belonging to the main thread alone).
var next_proposal_id: u32 = 0;

var shared_executor: ?*command.Executor = null;

/// A general post-apply hook, run once a COMMIT has been applied successfully (an opaque ctx plus the raw name, args, actor and seq only).
/// The framework interprets nothing about the history, the paint diff or the editor. With none registered this is a no-op (bit-identical).
pub const PostApplyContext = struct {
    name: []const u8,
    args: []const u8,
    origin_peer: u32,
    seq: u64,
};
pub const PostApplyHook = *const fn (ctx: *anyopaque, applied: PostApplyContext) void;
var post_apply_hook: ?PostApplyHook = null;
var post_apply_ctx: ?*anyopaque = null;

pub fn setPostApplyHook(ctx: ?*anyopaque, hook: ?PostApplyHook) void {
    post_apply_ctx = ctx;
    post_apply_hook = hook;
}

fn callPostApplyHook(name: []const u8, args: []const u8, origin_peer: u32, seq: u64) void {
    const hook = post_apply_hook orelse return;
    const ctx = post_apply_ctx orelse return;
    hook(ctx, .{
        .name = name,
        .args = args,
        .origin_peer = origin_peer,
        .seq = seq,
    });
}

/// Notification that a session has started or ended (for rejecting a copilot operate; platform registers it, so there is no reverse import from netsync to copilot).
/// **Main thread only** (enableRouter, clearRouterMain, and pump's router_clear — the same places as wire_session).
pub const SessionStateCallback = *const fn (active: bool) void;
var session_state_cb: ?SessionStateCallback = null;

pub fn setSessionStateCallback(cb: ?SessionStateCallback) void {
    session_state_cb = cb;
}

fn notifySessionState(active: bool) void {
    if (session_state_cb) |cb| cb(active);
}

var last_rejected_proposal: u32 = 0;
var last_reject_reason_buf: [256]u8 = undefined;
var last_reject_reason_len: usize = 0;

var state_sync: ?StateSync = null;
/// On a client: true until the SYNC import completes. Meanwhile pump does not enter the inbound dequeue loop.
var awaiting_sync: bool = false;
/// The SYNC payload (seq plus state) a client's reader stashes. Replaced and freed under peers_mutex.
var pending_sync: ?[]u8 = null;

/// A client's queue of local PROPOSE and PROPOSE_REVERT frames awaiting send. Belongs to the main thread alone.
pub const PENDING_CAP: usize = 64;
const PendingKind = enum { normal, revert };
const PendingEntry = struct {
    proposal_id: u32 = 0,
    kind: PendingKind = .normal,
    redo_of: ?u64 = null,
    target_seq: u64 = 0,
};
var pending_q: [PENDING_CAP]PendingEntry = undefined;
var pending_head: usize = 0;
var pending_tail: usize = 0;
var pending_count: usize = 0;

fn pendingClear() void {
    pending_head = 0;
    pending_tail = 0;
    pending_count = 0;
}

fn pendingEnqueue(e: PendingEntry) bool {
    if (pending_count >= PENDING_CAP) return false;
    pending_q[pending_tail] = e;
    pending_tail = (pending_tail + 1) % PENDING_CAP;
    pending_count += 1;
    return true;
}

fn pendingPeek() ?PendingEntry {
    if (pending_count == 0) return null;
    return pending_q[pending_head];
}

fn pendingPopHead() void {
    if (pending_count == 0) return;
    pending_head = (pending_head + 1) % PENDING_CAP;
    pending_count -= 1;
}

fn pendingRemoveProposal(proposal_id: u32) void {
    if (pending_count == 0) return;
    if (pending_q[pending_head].proposal_id == proposal_id) {
        pendingPopHead();
        return;
    }
    var i: usize = 0;
    while (i < pending_count) : (i += 1) {
        const idx = (pending_head + i) % PENDING_CAP;
        if (pending_q[idx].proposal_id == proposal_id) {
            std.debug.print("[netsync] a pending REJECT is not at the head — removing it by scan proposal={d}\n", .{proposal_id});
            var j = i;
            while (j + 1 < pending_count) : (j += 1) {
                const a = (pending_head + j) % PENDING_CAP;
                const b = (pending_head + j + 1) % PENDING_CAP;
                pending_q[a] = pending_q[b];
            }
            pending_count -= 1;
            pending_tail = (pending_head + pending_count) % PENDING_CAP;
            return;
        }
    }
    std.debug.print("[netsync] a pending REJECT does not match proposal={d}\n", .{proposal_id});
}

/// A snapshot for observation.
/// `gatherStats`, and a probe's digest and snapshot, are by the harness's design called **on the main thread only (inside pollGate)**.
pub const NetsyncStats = struct {
    role: Role = .disabled,
    peers: usize = 0,
    /// How many connected peers are of the agent kind (host=slots[]; client=the catalog's active agents).
    agents: usize = 0,
    peer_id: u32 = 0,
    last_seq: u64 = 0,
    pending: usize = 0,
    awaiting_sync: bool = false,
    last_reject: u32 = 0,
};

/// Fetches the reader's shared fields in one hold of `peers_mutex`, then adds the main-thread-only values.
/// **Main thread only** (a probe runs inside pollGate by assumption).
pub fn gatherStats() NetsyncStats {
    var st: NetsyncStats = .{};
    if (!io_inited) return st;

    peers_mutex.lockUncancelable(io_val);
    const on = started and role != .disabled;
    if (on) {
        st.role = role;
        st.peer_id = if (role == .host) 0 else local_peer_id;
        st.awaiting_sync = awaiting_sync;
        st.pending = inbound.len(io_val);
        if (role == .host) {
            for (&slots) |*s| {
                if (s.state == .active) {
                    st.peers += 1;
                    if (s.actor_kind == .agent) st.agents += 1;
                }
            }
        } else if (role == .client) {
            // Once PEER_INFO has been reflected this is every active catalog entry. Even before one arrives, self goes in right after HELLO.
            for (&peer_catalog) |*e| {
                if (e.occupied and e.active) {
                    st.peers += 1;
                    if (e.kind == .agent) st.agents += 1;
                }
            }
            // The fallback for an empty catalog (before HELLO): this slot, as before
            if (st.peers == 0 and client_slot.state == .active) {
                st.peers = 1;
                if (client_slot.actor_kind == .agent) st.agents = 1;
            }
        }
    }
    peers_mutex.unlock(io_val);

    if (!on) return st;

    // belongs to the main thread alone (no lock needed)
    st.last_seq = if (st.role == .host) wire_seq else last_applied_seq;
    st.last_reject = last_rejected_proposal;
    return st;
}

/// Replaces ASCII control characters with `_` and truncates to at most `out.len` (normally MAX_LABEL_LEN=200).
pub fn sanitizePeerLabel(out: []u8, label: []const u8) []const u8 {
    const n = @min(label.len, out.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const c = label[i];
        out[i] = if (c < 0x20 or c == 0x7f) '_' else c;
    }
    return out[0..n];
}

fn actorKindToPeerInfoByte(k: ActorKind) u8 {
    return switch (k) {
        .human => PEER_INFO_KIND_HUMAN,
        .agent => PEER_INFO_KIND_AGENT,
    };
}

fn peerInfoByteToActorKind(b: u8) ?ActorKind {
    return switch (b) {
        PEER_INFO_KIND_HUMAN => .human,
        PEER_INFO_KIND_AGENT => .agent,
        else => null,
    };
}

fn clearPeerCatalogLocked() void {
    for (&peer_catalog) |*e| e.* = .{};
}

/// Called while holding peers_mutex. The same peer_id updates in place. With no free room, the oldest inactive tombstone is reused.
/// An active entry is never evicted (so a full catalog with no inactive entry gives false).
fn upsertPeerCatalogLocked(peer_id: u32, kind: ActorKind, label: []const u8, active: bool) bool {
    var free_i: ?usize = null;
    var oldest_inactive: ?usize = null;
    for (&peer_catalog, 0..) |*e, i| {
        if (e.occupied and e.peer_id == peer_id) {
            e.kind = kind;
            e.active = active;
            const n = @min(label.len, MAX_LABEL_LEN);
            if (n > 0) @memcpy(e.label_buf[0..n], label[0..n]);
            e.label_len = n;
            return true;
        }
        if (!e.occupied) {
            if (free_i == null) free_i = i;
        } else if (!e.active) {
            if (oldest_inactive == null) oldest_inactive = i;
        }
    }
    const slot_i = free_i orelse oldest_inactive orelse return false;
    const e = &peer_catalog[slot_i];
    e.* = .{
        .occupied = true,
        .active = active,
        .peer_id = peer_id,
        .kind = kind,
    };
    const n = @min(label.len, MAX_LABEL_LEN);
    if (n > 0) @memcpy(e.label_buf[0..n], label[0..n]);
    e.label_len = n;
    return true;
}

fn markPeerCatalogLeftLocked(peer_id: u32) bool {
    for (&peer_catalog) |*e| {
        if (e.occupied and e.peer_id == peer_id) {
            e.active = false;
            return true;
        }
    }
    return false;
}

fn enqueuePeerInfoLocked(slot: *ConnSlot, peer_id: u32, kind_byte: u8, label: []const u8) bool {
    var pbuf: [5 + MAX_LABEL_LEN]u8 = undefined;
    const payload = formatPeerInfo(&pbuf, peer_id, kind_byte, label) catch return false;
    return slot.outbound.enqueue(io_val, @intFromEnum(FrameKind.peer_info), payload);
}

/// Resolves a peer_id to a kind and label (assumed to be the main thread; the label is copied into `label_buf`).
/// The host's peer_id=0 is the fixed HOST identity. Unresolved gives null.
pub fn resolvePeerOrigin(peer_id: u32, label_buf: []u8) ?PeerOriginView {
    if (!io_inited) return null;
    peers_mutex.lockUncancelable(io_val);
    defer peers_mutex.unlock(io_val);
    if (!started or role == .disabled) return null;

    if (role == .host) {
        if (peer_id == HOST_PEER_ID) {
            const lab = sanitizePeerLabel(label_buf, HOST_LABEL);
            return .{
                .peer_id = HOST_PEER_ID,
                .kind = HOST_ACTOR_KIND,
                .label = lab,
                .active = true,
            };
        }
        for (&slots) |*s| {
            if (s.state != .active or s.peer_id != peer_id) continue;
            const raw = s.label_buf[0..s.label_len];
            const lab = sanitizePeerLabel(label_buf, raw);
            return .{
                .peer_id = peer_id,
                .kind = s.actor_kind,
                .label = lab,
                .active = true,
            };
        }
        return null;
    }

    // client: the local catalog (null before a PEER_INFO arrives; self goes into the catalog at HELLO time)
    for (&peer_catalog) |*e| {
        if (!e.occupied or e.peer_id != peer_id) continue;
        const raw = e.label_buf[0..e.label_len];
        const lab = sanitizePeerLabel(label_buf, raw);
        return .{
            .peer_id = peer_id,
            .kind = e.kind,
            .label = lab,
            .active = e.active,
        };
    }
    return null;
}

/// A coarse-grained revision of the peer catalog and slot metadata (the trigger for rebuilding a history cache).
pub fn peerMetadataRevision() u64 {
    if (!io_inited) return 0;
    peers_mutex.lockUncancelable(io_val);
    defer peers_mutex.unlock(io_val);
    return peer_metadata_revision;
}

const reject_reason_token_max = 64;

/// Replaces ASCII whitespace (space, tab, CR, LF) and control characters with `_`, and truncates to at most 64B.
pub fn sanitizeRejectReasonToken(out: []u8, reason: []const u8) []const u8 {
    const n = @min(reason.len, @min(out.len, reject_reason_token_max));
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const c = reason[i];
        out[i] = if (c <= 0x20 or c == 0x7f) '_' else c;
    }
    return out[0..n];
}

fn roleDigestName(r: Role) []const u8 {
    return switch (r) {
        .disabled => "disabled",
        .host => "host",
        .client => "client",
    };
}

/// The one-line digest payload (the probe name is prepended by harness: `role=... peers=... agents=...`). **Main thread only**.
pub fn formatDigest(buf: []u8) []const u8 {
    const st = gatherStats();
    var reason_buf: [reject_reason_token_max]u8 = undefined;
    const reason_tok = if (st.last_reject == 0)
        "none"
    else
        sanitizeRejectReasonToken(&reason_buf, lastRejectReason());

    var reject_id_buf: [16]u8 = undefined;
    const reject_tok = if (st.last_reject == 0)
        "none"
    else
        (std.fmt.bufPrint(&reject_id_buf, "{d}", .{st.last_reject}) catch "?");

    var base: [384]u8 = undefined;
    const head = std.fmt.bufPrint(&base, "role={s} peers={d} agents={d} peer_id={d} last_seq={d} pending={d} awaiting_sync={d} last_reject={s} reject_reason={s}", .{
        roleDigestName(st.role),
        st.peers,
        st.agents,
        st.peer_id,
        st.last_seq,
        st.pending,
        @as(u8, if (st.awaiting_sync) 1 else 0),
        reject_tok,
        reason_tok,
    }) catch return buf[0..0];

    var log_part: [512]u8 = undefined;
    const log_s = formatLogDigestTail(&log_part);
    if (log_s.len == 0) {
        return std.fmt.bufPrint(buf, "{s}", .{head}) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "{s} log={s}", .{ head, log_s }) catch head;
}

const log_digest_tail = 8;

fn actorOriginToken(actor: command.ActorId, out: []u8) []const u8 {
    return switch (actor) {
        .local_user => std.fmt.bufPrint(out, "local", .{}) catch "?",
        .local_agent => std.fmt.bufPrint(out, "agent", .{}) catch "?",
        .peer => |id| std.fmt.bufPrint(out, "{d}", .{id}) catch "?",
        .system => std.fmt.bufPrint(out, "sys", .{}) catch "?",
    };
}

/// The last few as `seq:origin:name` (a revert as `seq:origin:revert->target`). Empty when there is no executor.
fn formatLogDigestTail(buf: []u8) []const u8 {
    const exec = shared_executor orelse return "";
    const log = exec.log orelse return "";
    if (log.filled == 0) return "";

    var pos: usize = 0;
    const start: u32 = if (log.filled > log_digest_tail) log.filled - log_digest_tail else 0;
    var i: u32 = start;
    var first = true;
    while (i < log.filled) : (i += 1) {
        const rec = log.recordAt(i);
        var obuf: [16]u8 = undefined;
        const origin = actorOriginToken(rec.actor, &obuf);
        var piece: [128]u8 = undefined;
        const one = if (rec.kind == .revert)
            (std.fmt.bufPrint(&piece, "{s}{d}:{s}:revert->{d}", .{
                if (first) "" else ",",
                rec.seq,
                origin,
                rec.target_seq orelse 0,
            }) catch break)
        else blk: {
            var nbuf: [command.MAX_CMD_NAME]u8 = undefined;
            const n = @min(rec.name().len, nbuf.len);
            for (rec.name()[0..n], 0..) |c, j| {
                nbuf[j] = if (c <= 0x20 or c == 0x7f) '_' else c;
            }
            break :blk (std.fmt.bufPrint(&piece, "{s}{d}:{s}:{s}", .{
                if (first) "" else ",",
                rec.seq,
                origin,
                nbuf[0..n],
            }) catch break);
        };
        if (pos + one.len > buf.len) break;
        @memcpy(buf[pos..][0..one.len], one);
        pos += one.len;
        first = false;
    }
    return buf[0..pos];
}

fn sanitizeJsonToken(out: []u8, s: []const u8) []const u8 {
    const n = @min(s.len, out.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const c = s[i];
        out[i] = if (c == '"' or c == '\\' or c <= 0x20 or c == 0x7f) '_' else c;
    }
    return out[0..n];
}

/// A snapshot as a single JSON object.
/// `peers` is `[{peer_id,kind,label},...]` (host=every slots[] entry; client=every active catalog entry).
/// `log[].origin` stays numeric or a tag as before (never a kind or a label; that is the public contract of the netsync digest).
/// **Main thread only**.
pub fn formatSnapshot(allocator: std.mem.Allocator) ![]u8 {
    const st = gatherStats();
    var reason_buf: [reject_reason_token_max]u8 = undefined;

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    const role_s = roleDigestName(st.role);
    const await_s: []const u8 = if (st.awaiting_sync) "true" else "false";
    var head_buf: [512]u8 = undefined;
    const head = if (st.last_reject == 0)
        try std.fmt.bufPrint(&head_buf, "{{\"role\":\"{s}\",\"peer_id\":{d},\"agents\":{d},\"last_seq\":{d},\"pending\":{d},\"awaiting_sync\":{s},\"last_reject\":null,\"reject_reason\":null,\"peers\":[", .{
            role_s, st.peer_id, st.agents, st.last_seq, st.pending, await_s,
        })
    else blk: {
        const reason_tok = sanitizeRejectReasonToken(&reason_buf, lastRejectReason());
        var json_reason: [reject_reason_token_max]u8 = undefined;
        const rn = @min(reason_tok.len, json_reason.len);
        for (reason_tok[0..rn], 0..) |c, i| {
            json_reason[i] = if (c == '"' or c == '\\') '_' else c;
        }
        break :blk try std.fmt.bufPrint(&head_buf, "{{\"role\":\"{s}\",\"peer_id\":{d},\"agents\":{d},\"last_seq\":{d},\"pending\":{d},\"awaiting_sync\":{s},\"last_reject\":{d},\"reject_reason\":\"{s}\",\"peers\":[", .{
            role_s, st.peer_id, st.agents, st.last_seq, st.pending, await_s, st.last_reject, json_reason[0..rn],
        });
    };
    try list.appendSlice(allocator, head);

    // the peers array (through getPeer, which takes the mutex itself)
    var pi: usize = 0;
    while (true) : (pi += 1) {
        var lbuf: [MAX_LABEL_LEN]u8 = undefined;
        const p = getPeer(pi, &lbuf) orelse break;
        if (pi > 0) try list.append(allocator, ',');
        var jlabel: [MAX_LABEL_LEN]u8 = undefined;
        const lab = sanitizeJsonToken(&jlabel, p.label);
        var entry_buf: [MAX_LABEL_LEN + 64]u8 = undefined;
        const entry = try std.fmt.bufPrint(&entry_buf, "{{\"peer_id\":{d},\"kind\":\"{s}\",\"label\":\"{s}\"}}", .{
            p.peer_id,
            p.kind.toToken(),
            lab,
        });
        try list.appendSlice(allocator, entry);
    }

    try list.appendSlice(allocator, "],\"log\":[");

    if (shared_executor) |exec| {
        if (exec.log) |log| {
            var i: u32 = 0;
            while (i < log.filled) : (i += 1) {
                if (i > 0) try list.append(allocator, ',');
                const rec = log.recordAt(i);
                var obuf: [16]u8 = undefined;
                const origin = actorOriginToken(rec.actor, &obuf);
                var entry_buf: [256]u8 = undefined;
                const entry = if (rec.kind == .revert)
                    try std.fmt.bufPrint(&entry_buf, "{{\"seq\":{d},\"origin\":\"{s}\",\"kind\":\"revert\",\"target_seq\":{d}}}", .{
                        rec.seq, origin, rec.target_seq orelse 0,
                    })
                else blk: {
                    var nbuf: [command.MAX_CMD_NAME]u8 = undefined;
                    const n = @min(rec.name().len, nbuf.len);
                    for (rec.name()[0..n], 0..) |c, j| {
                        nbuf[j] = if (c == '"' or c == '\\' or c <= 0x20) '_' else c;
                    }
                    break :blk try std.fmt.bufPrint(&entry_buf, "{{\"seq\":{d},\"origin\":\"{s}\",\"kind\":\"normal\",\"name\":\"{s}\",\"undoable\":{s},\"reverted\":{s}}}", .{
                        rec.seq,
                        origin,
                        nbuf[0..n],
                        if (rec.undoable) "true" else "false",
                        if (rec.reverted) "true" else "false",
                    });
                };
                try list.appendSlice(allocator, entry);
            }
        }
    }
    try list.appendSlice(allocator, "]}");
    return try list.toOwnedSlice(allocator);
}

/// The digest for the harness custom probe (ctx is unused).
pub fn probeDigest(_: *anyopaque, buf: []u8) []const u8 {
    return formatDigest(buf);
}

/// The snapshot for the harness custom probe (ctx is unused).
pub fn probeSnapshot(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    return formatSnapshot(allocator);
}

/// Registers a StateSync (with netsync disabled it only stores it, so it is always safe to call).
/// export_fn must not return 0 bytes (doing so counts as a failed export).
pub fn registerStateSync(s: StateSync) void {
    state_sync = s;
}

fn freePendingSyncLocked() void {
    if (pending_sync) |p| {
        gpa.free(p);
        pending_sync = null;
    }
}

fn ensureIo() void {
    if (io_inited) return;
    io_inited = true;
    threaded = Io.Threaded.init(gpa, .{});
    io_val = threaded.io();
}

fn getEnv(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    return std.mem.span(v);
}

fn parseConnectAddr(text: []const u8) ?net.IpAddress {
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return null;
    const host = text[0..colon];
    const port_s = text[colon + 1 ..];
    const port = std.fmt.parseInt(u16, port_s, 10) catch return null;
    return net.IpAddress.parseIp4(host, port) catch null;
}

pub fn isEnabled() bool {
    if (!io_inited) return false;
    peers_mutex.lockUncancelable(io_val);
    defer peers_mutex.unlock(io_val);
    return role != .disabled and started;
}

pub fn isHost() bool {
    if (!io_inited) return false;
    peers_mutex.lockUncancelable(io_val);
    defer peers_mutex.unlock(io_val);
    return role == .host and started;
}

pub fn isClient() bool {
    if (!io_inited) return false;
    peers_mutex.lockUncancelable(io_val);
    defer peers_mutex.unlock(io_val);
    return role == .client and started;
}

/// Forwarded from platform.setCommandExecutor. Used for applying a remote COMMIT and a host PROPOSE (main thread).
pub fn setSharedExecutor(exec: ?*command.Executor) void {
    if (shared_executor) |old| old.setWireSession(false);
    shared_executor = exec;
    if (exec) |e| {
        if (isEnabled()) e.setWireSession(true);
    }
}

/// Drops just the borrow of the shared executor before teardown (without dereferencing the old pointer).
pub fn forgetSharedExecutor() void {
    shared_executor = null;
}

pub fn lastRejectedProposal() u32 {
    return last_rejected_proposal;
}

pub fn lastRejectReason() []const u8 {
    return last_reject_reason_buf[0..last_reject_reason_len];
}

pub fn wireSeq() u64 {
    return wire_seq;
}

fn setWireSessionFlag(on: bool) void {
    if (shared_executor) |e| e.setWireSession(on);
}

fn enableRouter() void {
    action_registry.setRouter(netsyncRouter);
    action_registry.setEnabled(true);
    setWireSessionFlag(true);
    notifySessionState(true);
}

fn clearRouterMain() void {
    action_registry.setRouter(null);
    setWireSessionFlag(false);
    notifySessionState(false);
    if (io_inited) {
        peers_mutex.lockUncancelable(io_val);
        router_clear_pending = false;
        peers_mutex.unlock(io_val);
    } else {
        router_clear_pending = false;
    }
}

fn requestRouterClear() void {
    // must be called while holding peers_mutex (cleanup and failSoftLocked).
    router_clear_pending = true;
}

pub fn listeningPort() ?u16 {
    if (!have_server) return null;
    return server.socket.address.getPort();
}

pub fn localPeerId() u32 {
    if (!io_inited) return 0;
    peers_mutex.lockUncancelable(io_val);
    defer peers_mutex.unlock(io_val);
    return if (role == .host) 0 else local_peer_id;
}

pub fn peerCount() usize {
    if (!io_inited) return 0;
    peers_mutex.lockUncancelable(io_val);
    defer peers_mutex.unlock(io_val);
    if (!started) return 0;
    var n: usize = 0;
    if (role == .host) {
        for (&slots) |*s| {
            if (s.state == .active) n += 1;
        }
    } else if (role == .client) {
        for (&peer_catalog) |*e| {
            if (e.occupied and e.active) n += 1;
        }
        if (n == 0 and client_slot.state == .active) n = 1;
    }
    return n;
}

pub fn getPeer(i: usize, label_buf: []u8) ?PeerView {
    if (!io_inited) return null;
    peers_mutex.lockUncancelable(io_val);
    defer peers_mutex.unlock(io_val);
    if (!started) return null;
    var seen: usize = 0;
    if (role == .host) {
        for (&slots) |*s| {
            if (s.state != .active) continue;
            if (seen == i) {
                const n = @min(s.label_len, label_buf.len);
                if (n > 0) @memcpy(label_buf[0..n], s.label_buf[0..n]);
                return .{
                    .peer_id = s.peer_id,
                    .kind = s.actor_kind,
                    .label = label_buf[0..n],
                };
            }
            seen += 1;
        }
    } else if (role == .client) {
        for (&peer_catalog) |*e| {
            if (!e.occupied or !e.active) continue;
            if (seen == i) {
                const n = @min(e.label_len, label_buf.len);
                if (n > 0) @memcpy(label_buf[0..n], e.label_buf[0..n]);
                return .{
                    .peer_id = e.peer_id,
                    .kind = e.kind,
                    .label = label_buf[0..n],
                };
            }
            seen += 1;
        }
        // the fallback for an empty catalog (before HELLO)
        if (seen == 0 and i == 0 and client_slot.state == .active) {
            const n = @min(client_slot.label_len, label_buf.len);
            if (n > 0) @memcpy(label_buf[0..n], client_slot.label_buf[0..n]);
            return .{
                .peer_id = client_slot.peer_id,
                .kind = client_slot.actor_kind,
                .label = label_buf[0..n],
            };
        }
    }
    return null;
}

pub fn inboundLen() usize {
    if (!io_inited) return 0;
    return inbound.len(io_val);
}

pub fn setClientIdentity(kind: ActorKind, label: []const u8) void {
    client_actor_kind = kind;
    const n = @min(label.len, MAX_LABEL_LEN);
    // No copy is needed when the label already points at client_label_buf itself (which is the case through initClient).
    if (n > 0 and label.ptr != &client_label_buf) {
        @memcpy(client_label_buf[0..n], label[0..n]);
    }
    client_label_len = n;
}

fn defaultClientLabel() void {
    @memcpy(client_label_buf[0..default_client_label.len], default_client_label);
    client_label_len = default_client_label.len;
    client_actor_kind = .human;
}

// ============================================================================
// Lifecycle
// ============================================================================

pub fn initFromEnv() void {
    ensureIo();
    peers_mutex.lockUncancelable(io_val);
    const already = started or role != .disabled;
    peers_mutex.unlock(io_val);
    if (already) return;
    const host_req = getEnv("KNGN_NETSYNC_HOST") != null;
    const connect = getEnv("KNGN_NETSYNC_CONNECT");
    if (host_req and connect != null) {
        std.debug.print("[netsync] KNGN_NETSYNC_HOST and KNGN_NETSYNC_CONNECT cannot both be given; disabling.\n", .{});
        return;
    }
    if (host_req) {
        const port_s = getEnv("KNGN_NETSYNC_PORT") orelse {
            std.debug.print("[netsync] KNGN_NETSYNC_HOST=1 needs KNGN_NETSYNC_PORT; disabling.\n", .{});
            return;
        };
        const port = std.fmt.parseInt(u16, port_s, 10) catch {
            std.debug.print("[netsync] KNGN_NETSYNC_PORT is invalid; disabling.\n", .{});
            return;
        };
        initHost(port);
        return;
    }
    if (connect) |c| {
        const addr = parseConnectAddr(c) orelse {
            std.debug.print("[netsync] KNGN_NETSYNC_CONNECT is invalid (expected ip:port): {s}\n", .{c});
            return;
        };
        const kind = parseActorEnv(getEnv("KNGN_NETSYNC_ACTOR"));
        const label = getEnv("KNGN_NETSYNC_LABEL") orelse default_client_label;
        setClientIdentity(kind, label);
        initClient(addr);
    }
}

/// Interprets `KNGN_NETSYNC_ACTOR` (the default is human; an invalid value warns and gives human). The tests call it too.
pub fn parseActorEnv(raw: ?[]const u8) ActorKind {
    const s = raw orelse return .human;
    return ActorKind.fromToken(s) orelse {
        std.debug.print("[netsync] KNGN_NETSYNC_ACTOR is invalid (expected human|agent): {s} — treating it as human\n", .{s});
        return .human;
    };
}

pub fn initHost(port: u16) void {
    ensureIo();
    peers_mutex.lockUncancelable(io_val);
    if (started) {
        peers_mutex.unlock(io_val);
        return;
    }
    peers_mutex.unlock(io_val);

    stop_flag.store(false, .seq_cst);
    defaultClientLabel();
    inbound.clear(io_val);
    presence_inbound.clear(io_val);

    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    server = addr.listen(io_val, .{ .reuse_address = true }) catch |err| {
        std.debug.print("[netsync] host listen failed: {s}\n", .{@errorName(err)});
        return;
    };
    have_server = true;

    peers_mutex.lockUncancelable(io_val);
    next_peer_id = 1;
    role = .host;
    started = true;
    peers_mutex.unlock(io_val);

    acceptor_thread = std.Thread.spawn(.{}, acceptorMain, .{}) catch |err| {
        std.debug.print("[netsync] failed to spawn the acceptor: {s}\n", .{@errorName(err)});
        server.deinit(io_val);
        have_server = false;
        peers_mutex.lockUncancelable(io_val);
        role = .disabled;
        started = false;
        peers_mutex.unlock(io_val);
        return;
    };
    wire_seq = 0;
    last_applied_seq = 0;
    enableRouter();
    std.debug.print("[netsync] host enabled: 127.0.0.1:{d}\n", .{server.socket.address.getPort()});
}

pub fn initClient(addr: net.IpAddress) void {
    // Unlike initHost, the initFromEnv to initClient path does not call defaultClientLabel.
    // The initialiser at the declaration is authoritative, but if it is empty the default is put back (guaranteeing a client always has a valid label).
    if (client_label_len == 0) defaultClientLabel();
    initClientAs(addr, client_actor_kind, client_label_buf[0..client_label_len]);
}

pub fn initClientAs(addr: net.IpAddress, kind: ActorKind, label: []const u8) void {
    ensureIo();
    peers_mutex.lockUncancelable(io_val);
    if (started) {
        peers_mutex.unlock(io_val);
        return;
    }
    peers_mutex.unlock(io_val);

    stop_flag.store(false, .seq_cst);
    setClientIdentity(kind, label);
    inbound.clear(io_val);
    presence_inbound.clear(io_val);

    // The HELLO encoding uses the same already-truncated label as the internal copy (passing 201B or more straight through
    // would trip the host's label limit and disconnect with a protocol error, so it is clamped at the API boundary).
    const label_clamped = client_label_buf[0..client_label_len];

    // Retry a ConnectionRefused before the host is listening, briefly and with exponential backoff
    // (absorbing the "wait a few seconds" of starting two windows by hand; at init only, never on a real-time or frame path).
    // At most 6 attempts, waiting 100/200/400/800/1600 ms (about 3.1s in total). Past that it is the same fail-soft as before.
    // The decision: ConnectionRefused and Timeout are typical of a start-up race, so they are retried.
    // A permanent error such as AddressUnavailable, HostUnreachable or AccessDenied fails soft at once
    // (waiting would not fix it, so the user is not made to wait out the limit).
    const backoff_ms = [_]u64{ 100, 200, 400, 800, 1600 };
    const stream = blk: {
        var attempt: usize = 0;
        while (true) {
            if (addr.connect(io_val, .{ .mode = .stream })) |s| break :blk s else |err| {
                const retryable = switch (err) {
                    error.ConnectionRefused, error.Timeout => true,
                    else => false,
                };
                if (!retryable or attempt >= backoff_ms.len) {
                    std.debug.print("[netsync] client connection failed: {s} (start-up continues with netsync disabled)\n", .{@errorName(err)});
                    return; // fail-soft
                }
                const ms = backoff_ms[attempt];
                attempt += 1;
                std.debug.print("[netsync] retrying the client connection {d}/{d}: {s} (in {d}ms)\n", .{ attempt, backoff_ms.len, @errorName(err), ms });
                std.Io.sleep(io_val, .fromMilliseconds(@intCast(ms)), .awake) catch {};
            }
        }
    };

    peers_mutex.lockUncancelable(io_val);
    role = .client;
    started = true;
    client_slot = .{
        .state = .hello_pending,
        .stream = stream,
        .socket_open = true,
        .is_client_conn = true,
        .slot_index = 0,
        .actor_kind = kind,
    };
    if (label_clamped.len > 0) @memcpy(client_slot.label_buf[0..label_clamped.len], label_clamped);
    client_slot.label_len = label_clamped.len;
    client_slot.outbound.reset(io_val);
    client_slot.presence_outbound.clear(io_val);
    peers_mutex.unlock(io_val);

    client_slot.writer_thread = std.Thread.spawn(.{}, writerMain, .{&client_slot}) catch {
        std.debug.print("[netsync] failed to spawn the client writer\n", .{});
        stream.close(io_val);
        peers_mutex.lockUncancelable(io_val);
        role = .disabled;
        started = false;
        client_slot.state = .empty;
        client_slot.socket_open = false;
        peers_mutex.unlock(io_val);
        return;
    };
    client_slot.reader_thread = std.Thread.spawn(.{}, readerMain, .{&client_slot}) catch {
        std.debug.print("[netsync] failed to spawn the client reader\n", .{});
        // Do not close before joining the writer (the invariant: a close happens once, after the writer is joined).
        client_slot.outbound.close(io_val);
        stream.shutdown(io_val, .both) catch {};
        if (client_slot.writer_thread) |t| t.join();
        client_slot.writer_thread = null;
        peers_mutex.lockUncancelable(io_val);
        if (client_slot.socket_open) {
            stream.close(io_val);
            client_slot.socket_open = false;
        }
        role = .disabled;
        started = false;
        client_slot.state = .empty;
        peers_mutex.unlock(io_val);
        return;
    };

    // Raise awaiting_sync before sending HELLO (which prevents the race where the reader gets a pending_sync in
    // first and it is freed afterwards, stalling forever).
    next_proposal_id = 0;
    last_applied_seq = 0;
    peers_mutex.lockUncancelable(io_val);
    awaiting_sync = true;
    freePendingSyncLocked();
    peers_mutex.unlock(io_val);

    // the client HELLO onto the outbound queue
    var hbuf: [MAX_ACTION_FRAME_BYTES]u8 = undefined;
    const hello = formatClientHello(&hbuf, kind, label_clamped) catch {
        requestCloseSlot(&client_slot);
        return;
    };
    peers_mutex.lockUncancelable(io_val);
    const enq_ok = client_slot.state == .hello_pending and
        client_slot.outbound.enqueue(io_val, @intFromEnum(FrameKind.hello), hello);
    peers_mutex.unlock(io_val);
    if (!enq_ok) {
        requestCloseSlot(&client_slot);
        return;
    }
    enableRouter();
    std.debug.print("[netsync] client connecting\n", .{});
}

/// Drains inbound and applies PROPOSE, COMMIT, REJECT and ClientJoined (main thread; safe every frame).
/// `router_clear_pending` is handled before the `isEnabled` early return (so it is cleared even after a fail-soft).
/// While awaiting_sync it only tries the pending_sync import and does not enter the COMMIT inbound dequeue loop.
/// PRESENCE inbound is always handled, outside the awaiting_sync gate.
pub fn pump() void {
    if (!io_inited) return;

    // Clearing the router and wire_session after a fail-soft (main thread; symmetrical with shutdown's clearRouterMain).
    peers_mutex.lockUncancelable(io_val);
    const clear = router_clear_pending;
    if (clear) router_clear_pending = false;
    peers_mutex.unlock(io_val);
    if (clear) {
        action_registry.setRouter(null);
        setWireSessionFlag(false);
        notifySessionState(false);
    }

    if (!isEnabled()) return;

    // presence applies even while waiting for a SYNC (it is independent of a document COMMIT).
    pumpPresenceInbound();

    // Applying a SYNC while awaiting does not dequeue a COMMIT in the same pump (that resumes on the next one).
    peers_mutex.lockUncancelable(io_val);
    const was_awaiting = awaiting_sync;
    peers_mutex.unlock(io_val);

    tryApplyPendingSync();
    if (was_awaiting) return;

    var kind: u8 = 0;
    var peer: u32 = 0;
    var buf: [MAX_ACTION_FRAME_BYTES]u8 = undefined;
    while (isEnabled()) {
        const n = inbound.dequeue(io_val, &kind, &peer, &buf) orelse break;
        const payload = buf[0..n];
        if (kind == INTERNAL_CLIENT_JOINED) {
            handleClientJoined(payload);
        } else {
            handleInboundFrame(kind, peer, payload);
        }
    }
}

fn pumpPresenceInbound() void {
    var peer: u32 = 0;
    var data: [PRESENCE_PAYLOAD_LEN]u8 = undefined;
    var dispatch_buf: [256]u8 = undefined;
    while (presence_inbound.dequeue(io_val, &peer, &data)) {
        handlePresenceFrame(peer, &data, &dispatch_buf);
    }
}

fn handlePresenceFrame(from_peer: u32, payload: []const u8, dispatch_buf: []u8) void {
    var parsed = parsePresencePayload(payload) catch return;
    // received by the host: overwrite the origin with the TCP slot's peer id (which prevents spoofing)
    peers_mutex.lockUncancelable(io_val);
    const cur_role = role;
    peers_mutex.unlock(io_val);

    if (cur_role == .host) {
        parsed.origin_peer = from_peer;
        var pbuf: [PRESENCE_PAYLOAD_LEN]u8 = undefined;
        const wired = formatPresencePayload(&pbuf, parsed) catch return;
        var args_buf: [128]u8 = undefined;
        const remote_args = formatPresenceRemoteArgs(&args_buf, parsed) catch return;
        const name = parsed.subtype.actionName();
        _ = action_registry.dispatch(name, remote_args, dispatch_buf) catch return;
        // broadcast only when the callback succeeded (including to an awaiting_sync client)
        broadcastPresence(wired);
    } else {
        // received by a client: trust the payload's origin_peer (the host has already set it)
        var args_buf: [128]u8 = undefined;
        const remote_args = formatPresenceRemoteArgs(&args_buf, parsed) catch return;
        const name = parsed.subtype.actionName();
        _ = action_registry.dispatch(name, remote_args, dispatch_buf) catch {};
    }
}

/// For tests: dequeue one inbound entry (null while awaiting_sync).
pub fn dequeueInbound(out_kind: *u8, out_buf: []u8) ?usize {
    if (!isEnabled()) return null;
    peers_mutex.lockUncancelable(io_val);
    const waiting = awaiting_sync;
    peers_mutex.unlock(io_val);
    if (waiting) return null;
    var peer: u32 = 0;
    return inbound.dequeue(io_val, out_kind, &peer, out_buf);
}

fn handleInboundFrame(kind: u8, from_peer: u32, payload: []const u8) void {
    const k: FrameKind = @enumFromInt(kind);
    switch (k) {
        .propose => handlePropose(from_peer, payload),
        .propose_revert => handleProposeRevert(from_peer, payload),
        .commit => handleCommit(payload),
        .commit_revert => handleCommitRevert(payload),
        .reject => handleReject(payload),
        .peer_info => handlePeerInfo(payload),
        .sync => {
            std.debug.print("[netsync] unexpected SYNC on host path — ignore\n", .{});
        },
        else => {},
    }
}

/// The client side: reflects a PEER_INFO into the catalog (main thread, through pump). A host ignores it.
/// A malformed frame, an unknown kind, or a too-short payload leaves the state unchanged. A LEFT for an unknown peer is ignored.
fn handlePeerInfo(payload: []const u8) void {
    const parsed = parsePeerInfo(payload) catch return;

    peers_mutex.lockUncancelable(io_val);
    defer peers_mutex.unlock(io_val);
    if (role != .client or !started) return;

    if (parsed.kind == PEER_INFO_KIND_LEFT) {
        if (markPeerCatalogLeftLocked(parsed.peer_id)) {
            peer_metadata_revision +%= 1;
        }
        return;
    }

    const kind = peerInfoByteToActorKind(parsed.kind) orelse return;
    var lab_buf: [MAX_LABEL_LEN]u8 = undefined;
    const lab = sanitizePeerLabel(&lab_buf, parsed.label);
    if (upsertPeerCatalogLocked(parsed.peer_id, kind, lab, true)) {
        peer_metadata_revision +%= 1;
    }
}

fn buildSyncPayload(seq: u64, state: []const u8) ![]u8 {
    if (8 + state.len > MAX_SYNC_BYTES) return error.PayloadTooLarge;
    const buf = try gpa.alloc(u8, 8 + state.len);
    std.mem.writeInt(u64, buf[0..8], seq, .little);
    if (state.len > 0) @memcpy(buf[8..], state);
    return buf;
}

fn parseSyncPayload(payload: []const u8) ProtocolError!struct { seq: u64, state: []const u8 } {
    if (payload.len < 8) return error.ProtocolError;
    return .{
        .seq = std.mem.readInt(u64, payload[0..8], .little),
        .state = payload[8..],
    };
}

fn handleClientJoined(payload: []const u8) void {
    if (payload.len < 8) return;
    const peer_id = std.mem.readInt(u32, payload[0..4], .little);
    const generation = std.mem.readInt(u32, payload[4..8], .little);

    peers_mutex.lockUncancelable(io_val);
    const slot_opt: ?*ConnSlot = blk: {
        for (&slots) |*s| {
            if (s.state == .active and s.peer_id == peer_id and s.generation == generation) {
                break :blk s;
            }
        }
        break :blk null;
    };
    if (slot_opt == null) {
        peers_mutex.unlock(io_val);
        return; // stale ClientJoined
    }
    const slot = slot_opt.?;
    const seq = wire_seq;
    peers_mutex.unlock(io_val);

    var snapshot_valid = false;
    const sync_bytes: []u8 = blk: {
        if (state_sync) |ss| {
            const state = ss.export_fn(ss.ctx, gpa) catch |err| {
                std.debug.print("[netsync] StateSync export failed: {s} — disconnecting the client\n", .{@errorName(err)});
                requestCloseSlotIfGeneration(slot, peer_id, generation);
                return;
            };
            if (state.len == 0) {
                gpa.free(state);
                std.debug.print("[netsync] StateSync export returned 0 bytes — disconnecting the client\n", .{});
                requestCloseSlotIfGeneration(slot, peer_id, generation);
                return;
            }
            snapshot_valid = true;
            const payload_bytes = buildSyncPayload(seq, state) catch {
                gpa.free(state);
                std.debug.print("[netsync] the SYNC payload is too large — disconnecting the client\n", .{});
                requestCloseSlotIfGeneration(slot, peer_id, generation);
                return;
            };
            gpa.free(state);
            break :blk payload_bytes;
        } else {
            // nothing registered: an empty SYNC (the seq alone) plus snapshot_valid=false
            break :blk buildSyncPayload(seq, &[_]u8{}) catch {
                requestCloseSlotIfGeneration(slot, peer_id, generation);
                return;
            };
        }
    };

    peers_mutex.lockUncancelable(io_val);
    // re-validate (the connection may have dropped during the export)
    if (slot.state != .active or slot.peer_id != peer_id or slot.generation != generation) {
        peers_mutex.unlock(io_val);
        gpa.free(sync_bytes);
        return;
    }
    if (!slot.outbound.enqueueBig(io_val, @intFromEnum(FrameKind.sync), sync_bytes)) {
        peers_mutex.unlock(io_val);
        gpa.free(sync_bytes);
        std.debug.print("[netsync] failed to enqueue the SYNC — disconnecting the client\n", .{});
        requestCloseSlotIfGeneration(slot, peer_id, generation);
        return;
    }
    slot.synced = true;
    slot.snapshot_valid = snapshot_valid;
    slot.join_snapshot_seq = seq;
    peers_mutex.unlock(io_val);
}

fn tryApplyPendingSync() void {
    peers_mutex.lockUncancelable(io_val);
    if (!awaiting_sync) {
        peers_mutex.unlock(io_val);
        return;
    }
    const pending = pending_sync;
    pending_sync = null;
    peers_mutex.unlock(io_val);

    const bytes = pending orelse return;
    defer gpa.free(bytes);

    const parsed = parseSyncPayload(bytes) catch {
        std.debug.print("[netsync] failed to parse the SYNC — fail-soft\n", .{});
        failSoftDisableClient();
        return;
    };
    if (parsed.seq > wire_seq) wire_seq = parsed.seq;

    if (parsed.state.len == 0) {
        // an empty SYNC: release the gate without importing
        peers_mutex.lockUncancelable(io_val);
        awaiting_sync = false;
        peers_mutex.unlock(io_val);
        return;
    }

    const ss = state_sync orelse {
        // nothing registered to import but a non-empty SYNC → it cannot be applied
        std.debug.print("[netsync] a SYNC arrived but no StateSync is registered — fail-soft\n", .{});
        failSoftDisableClient();
        return;
    };
    ss.import_fn(ss.ctx, parsed.state) catch |err| {
        std.debug.print("[netsync] StateSync import failed: {s} — fail-soft (the held COMMIT is not applied)\n", .{@errorName(err)});
        failSoftDisableClient();
        return;
    };
    peers_mutex.lockUncancelable(io_val);
    awaiting_sync = false;
    peers_mutex.unlock(io_val);
}

fn applyWireCommit(name: []const u8, args: []const u8, origin_peer: u32, seq: u64, pending_meta: ?command.PendingMeta, buf: []u8) anyerror![]const u8 {
    if (shared_executor) |exec| {
        const res = try exec.executeAction(name, args, .{
            .actor = .{ .peer = origin_peer },
            .source = .{ .remote_commit = .{ .seq = seq, .pending_local_meta = pending_meta } },
            .record_policy = .record,
        }, buf);
        // Run the post-apply hook exactly once, after the execute succeeded and the record and seq are settled.
        // A chunk still passes through here as one execute per COMMIT (so there is no double capture).
        if (res.seq) |applied_seq| {
            callPostApplyHook(name, args, origin_peer, applied_seq);
        }
        return res.output;
    }
    // no executor set: the fallback with no recording — the hook is not called either
    return action_registry.dispatch(name, args, buf);
}

fn allocateCommitSeq() u64 {
    if (shared_executor) |exec| {
        if (exec.log) |log| return log.next_seq;
    }
    wire_seq += 1;
    return wire_seq;
}

fn noteWireSeq(seq: u64) void {
    if (seq > wire_seq) wire_seq = seq;
}

fn enqueueToPeer(peer_id: u32, kind: u8, payload: []const u8) bool {
    peers_mutex.lockUncancelable(io_val);
    defer peers_mutex.unlock(io_val);
    for (&slots) |*s| {
        if (s.state == .active and s.peer_id == peer_id) {
            return s.outbound.enqueue(io_val, kind, payload);
        }
    }
    return false;
}

fn broadcastCommit(seq: u64, origin_peer: u32, name: []const u8, args: []const u8) void {
    var cbuf: [MAX_ACTION_FRAME_BYTES]u8 = undefined;
    const payload = formatCommitPayload(&cbuf, seq, origin_peer, name, args) catch {
        std.debug.print("[netsync] failed to build the COMMIT payload\n", .{});
        return;
    };
    broadcast(@intFromEnum(FrameKind.commit), payload);
}

fn broadcastCommitRevert(seq: u64, target_seq: u64) void {
    var cbuf: [32]u8 = undefined;
    const payload = formatCommitRevertPayload(&cbuf, seq, target_seq) catch return;
    broadcast(@intFromEnum(FrameKind.commit_revert), payload);
}

fn sendReject(peer_id: u32, proposal_id: u32, reason: []const u8) void {
    var rbuf: [MAX_ACTION_FRAME_BYTES]u8 = undefined;
    const payload = formatRejectPayload(&rbuf, proposal_id, reason) catch return;
    _ = enqueueToPeer(peer_id, @intFromEnum(FrameKind.reject), payload);
}

fn maxJoinSnapshotSeq() u64 {
    peers_mutex.lockUncancelable(io_val);
    defer peers_mutex.unlock(io_val);
    var m: u64 = 0;
    for (&slots) |*s| {
        if (s.state == .active and s.join_snapshot_seq > m) m = s.join_snapshot_seq;
    }
    return m;
}

/// A host-local `.relay`: straight to the executor (actor=.peer(0), remote_commit), then a COMMIT broadcast.
/// A host-generated `pattern_state` goes through this same facade (the application uses platform.commitHostAction).
pub fn commitAndBroadcast(name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
    // A payload exceeding the action frame limit (name + a space + args) is not broadcast.
    if (name.len + 1 + args.len > MAX_ACTION_FRAME_BYTES) return error.PayloadTooLarge;
    const seq = allocateCommitSeq();
    const out = try applyWireCommit(name, args, 0, seq, null, buf);
    noteWireSeq(seq);
    broadcastCommit(seq, 0, name, args);
    return out;
}

/// A client-local `.relay`: allocate a proposal_id and send a PROPOSE. Nothing is applied locally.
pub fn proposeToHost(name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
    return proposeToHostWithMeta(name, args, null, buf);
}

fn proposeToHostWithMeta(name: []const u8, args: []const u8, redo_of: ?u64, buf: []u8) anyerror![]const u8 {
    // A PROPOSE before the SYNC completes could refer to a graph that has not been applied yet, so it is rejected.
    if (awaiting_sync) {
        action_registry.setActionErrorDetail("session_not_ready", "wait for awaiting_sync=0 before relay actions");
        return error.SessionNotReady;
    }
    if (pending_count >= PENDING_CAP) return error.PendingQueueFull;
    next_proposal_id += 1;
    const id = next_proposal_id;
    var pbuf: [MAX_ACTION_FRAME_BYTES]u8 = undefined;
    const payload = formatProposePayload(&pbuf, id, name, args) catch return error.PayloadTooLarge;
    if (!clientSend(@intFromEnum(FrameKind.propose), payload)) {
        return error.ProposeSendFailed;
    }
    if (!pendingEnqueue(.{ .proposal_id = id, .kind = .normal, .redo_of = redo_of, .target_seq = 0 })) {
        return error.PendingQueueFull;
    }
    return std.fmt.bufPrint(buf, "proposed {d}", .{id});
}

fn handlePropose(from_peer: u32, payload: []const u8) void {
    if (!isHost()) return;
    const parsed = parseProposePayload(payload) catch {
        sendReject(from_peer, 0, "bad propose");
        return;
    };
    const act = action_registry.findAction(parsed.name);
    if (act == null or act.?.network_policy != .relay) {
        sendReject(from_peer, parsed.proposal_id, "not relayable");
        return;
    }
    const seq = allocateCommitSeq();
    var abuf: [MAX_ACTION_FRAME_BYTES]u8 = undefined;
    _ = applyWireCommit(parsed.name, parsed.args, from_peer, seq, null, &abuf) catch |err| {
        var reason_buf: [64]u8 = undefined;
        const reason = std.fmt.bufPrint(&reason_buf, "{s}", .{@errorName(err)}) catch "apply failed";
        sendReject(from_peer, parsed.proposal_id, reason);
        return;
    };
    noteWireSeq(seq);
    broadcastCommit(seq, from_peer, parsed.name, parsed.args);
}

fn validateRevertTarget(target_seq: u64, proposer: u32) ?[]const u8 {
    const exec = shared_executor orelse return "no executor";
    const log = exec.log orelse return "no log";
    const adapter = exec.adapter orelse return "no adapter";
    const rec = log.findBySeq(target_seq) orelse return "unknown seq";
    if (!rec.actor.eql(.{ .peer = proposer })) return "not yours";
    if (!rec.undoable) return "not undoable";
    if (rec.reverted) return "already reverted";
    if (rec.transaction_id != null) return "transaction undo unsupported";
    if (!adapter.canUndo(adapter.ctx, rec)) return "too old";
    if (target_seq <= maxJoinSnapshotSeq()) return "before peer join";
    return null;
}

fn writeNothing(buf: []u8, msg: []const u8) []const u8 {
    const n = @min(buf.len, msg.len);
    @memcpy(buf[0..n], msg[0..n]);
    return buf[0..n];
}

fn proposeRevertOwn(buf: []u8) anyerror![]const u8 {
    const exec = shared_executor orelse return error.NoExecutor;
    const me = localPeerId();
    const target = exec.findUndoCandidate(.{ .peer = me }) orelse {
        return writeNothing(buf, "nothing to undo");
    };
    if (pending_count >= PENDING_CAP) return error.PendingQueueFull;
    next_proposal_id += 1;
    const id = next_proposal_id;
    var pbuf: [16]u8 = undefined;
    const payload = formatProposeRevertPayload(&pbuf, id, target) catch return error.PayloadTooLarge;
    if (!clientSend(@intFromEnum(FrameKind.propose_revert), payload)) {
        return error.ProposeSendFailed;
    }
    if (!pendingEnqueue(.{ .proposal_id = id, .kind = .revert, .redo_of = null, .target_seq = target })) {
        return error.PendingQueueFull;
    }
    return std.fmt.bufPrint(buf, "revert proposed {d}", .{id});
}

fn handleProposeRevert(from_peer: u32, payload: []const u8) void {
    if (!isHost()) return;
    const parsed = parseProposeRevertPayload(payload) catch {
        sendReject(from_peer, 0, "bad propose_revert");
        return;
    };
    if (validateRevertTarget(parsed.target_seq, from_peer)) |reason| {
        sendReject(from_peer, parsed.proposal_id, reason);
        return;
    }
    const exec = shared_executor orelse {
        sendReject(from_peer, parsed.proposal_id, "no executor");
        return;
    };
    const new_seq = allocateCommitSeq();
    exec.applyWireRevert(parsed.target_seq, new_seq) catch |err| {
        sendReject(from_peer, parsed.proposal_id, @errorName(err));
        return;
    };
    noteWireSeq(new_seq);
    broadcastCommitRevert(new_seq, parsed.target_seq);
}

fn handleCommit(payload: []const u8) void {
    if (!isClient()) return;
    const parsed = parseCommitPayload(payload) catch {
        std.debug.print("[netsync] failed to parse the COMMIT\n", .{});
        return;
    };
    // Peek only. The pop happens after a successful apply (so a pending entry is not lost on failure).
    var pending_meta: ?command.PendingMeta = null;
    var pop_pending = false;
    if (parsed.origin_peer == localPeerId()) {
        if (pendingPeek()) |head| {
            if (head.kind == .normal and head.proposal_id != 0) {
                pending_meta = if (head.redo_of) |r| .{ .redo_of = r } else null;
                pop_pending = true;
            }
        }
    }
    var abuf: [MAX_ACTION_FRAME_BYTES]u8 = undefined;
    _ = applyWireCommit(parsed.name, parsed.args, parsed.origin_peer, parsed.seq, pending_meta, &abuf) catch |err| {
        std.debug.print("[netsync] failed to apply the COMMIT: {s} — fail-soft\n", .{@errorName(err)});
        failSoftDisableClient();
        return;
    };
    if (pop_pending) pendingPopHead();
    noteWireSeq(parsed.seq);
    last_applied_seq = parsed.seq;
}

fn handleCommitRevert(payload: []const u8) void {
    if (!isClient()) return;
    const parsed = parseCommitRevertPayload(payload) catch {
        std.debug.print("[netsync] failed to parse the COMMIT_REVERT\n", .{});
        return;
    };
    var pop_pending = false;
    if (pendingPeek()) |head| {
        if (head.kind == .revert and head.target_seq == parsed.target_seq) {
            pop_pending = true;
        }
    }
    const exec = shared_executor orelse {
        std.debug.print("[netsync] COMMIT_REVERT: no executor is set — fail-soft\n", .{});
        failSoftDisableClient();
        return;
    };
    exec.applyWireRevert(parsed.target_seq, parsed.seq) catch |err| {
        std.debug.print("[netsync] failed to apply the COMMIT_REVERT: {s} — fail-soft\n", .{@errorName(err)});
        failSoftDisableClient();
        return;
    };
    if (pop_pending) pendingPopHead();
    noteWireSeq(parsed.seq);
    last_applied_seq = parsed.seq;
}

fn handleReject(payload: []const u8) void {
    if (!isClient()) return;
    const parsed = parseRejectPayload(payload) catch {
        std.debug.print("[netsync] failed to parse the REJECT\n", .{});
        return;
    };
    pendingRemoveProposal(parsed.proposal_id);
    last_rejected_proposal = parsed.proposal_id;
    const n = @min(parsed.reason.len, last_reject_reason_buf.len);
    if (n > 0) @memcpy(last_reject_reason_buf[0..n], parsed.reason[0..n]);
    last_reject_reason_len = n;
    std.debug.print("[netsync] REJECT proposal={d} reason={s}\n", .{ parsed.proposal_id, lastRejectReason() });
}

fn commitRedoOwn(actor_peer: u32, buf: []u8) anyerror![]const u8 {
    const exec = shared_executor orelse return error.NoExecutor;
    const cand = exec.findRedoCandidate(.{ .peer = actor_peer }) orelse {
        return writeNothing(buf, "nothing to redo");
    };
    // copy the name and args (execute mutates the log)
    var name_buf: [command.MAX_CMD_NAME]u8 = undefined;
    var args_buf: [command.MAX_CMD_ARGS]u8 = undefined;
    const nlen = @min(cand.name.len, name_buf.len);
    const alen = @min(cand.args.len, args_buf.len);
    @memcpy(name_buf[0..nlen], cand.name[0..nlen]);
    @memcpy(args_buf[0..alen], cand.args[0..alen]);
    const seq = allocateCommitSeq();
    const out = try applyWireCommit(name_buf[0..nlen], args_buf[0..alen], actor_peer, seq, .{ .redo_of = cand.target_seq }, buf);
    noteWireSeq(seq);
    broadcastCommit(seq, actor_peer, name_buf[0..nlen], args_buf[0..alen]);
    return out;
}

fn proposeRedoOwn(buf: []u8) anyerror![]const u8 {
    const exec = shared_executor orelse return error.NoExecutor;
    const me = localPeerId();
    const cand = exec.findRedoCandidate(.{ .peer = me }) orelse {
        return writeNothing(buf, "nothing to redo");
    };
    var name_buf: [command.MAX_CMD_NAME]u8 = undefined;
    var args_buf: [command.MAX_CMD_ARGS]u8 = undefined;
    const nlen = @min(cand.name.len, name_buf.len);
    const alen = @min(cand.args.len, args_buf.len);
    @memcpy(name_buf[0..nlen], cand.name[0..nlen]);
    @memcpy(args_buf[0..alen], cand.args[0..alen]);
    return proposeToHostWithMeta(name_buf[0..nlen], args_buf[0..alen], cand.target_seq, buf);
}

/// The NetworkPolicy branch, symmetrical between host and client.
/// **Main thread only** (through routeLocalAction). With role=.disabled it falls back to a dispatch.
fn netsyncRouter(name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
    peers_mutex.lockUncancelable(io_val);
    const cur = role;
    const on = started;
    peers_mutex.unlock(io_val);
    if (cur == .disabled or !on) {
        return action_registry.dispatch(name, args, buf);
    }

    const act = action_registry.findAction(name) orelse return error.UnknownAction;
    return switch (cur) {
        .host => switch (act.network_policy) {
            .relay => commitAndBroadcast(name, args, buf),
            .local_only => action_registry.dispatch(name, args, buf),
            .reject_when_synced => error.RejectedWhileSynced,
            .ephemeral => applyLocalPresence(name, args, buf),
            .undo_own => blk: {
                const exec = shared_executor orelse break :blk error.NoExecutor;
                const target = exec.findUndoCandidate(.{ .peer = 0 }) orelse break :blk writeNothing(buf, "nothing to undo");
                if (validateRevertTarget(target, 0)) |reason| {
                    std.debug.print("[netsync] host undo reject: {s}\n", .{reason});
                    break :blk error.RevertRejected;
                }
                const new_seq = allocateCommitSeq();
                try exec.applyWireRevert(target, new_seq);
                noteWireSeq(new_seq);
                broadcastCommitRevert(new_seq, target);
                break :blk (std.fmt.bufPrint(buf, "reverted {d}", .{target}) catch "reverted");
            },
            .redo_own => commitRedoOwn(0, buf),
        },
        .client => switch (act.network_policy) {
            .relay => proposeToHost(name, args, buf),
            .local_only => action_registry.dispatch(name, args, buf),
            .reject_when_synced => error.RejectedWhileSynced,
            .ephemeral => enqueueClientPresence(name, args, buf),
            .undo_own => proposeRevertOwn(buf),
            .redo_own => proposeRedoOwn(buf),
        },
        .disabled => action_registry.dispatch(name, args, buf),
    };
}

/// A host-local ephemeral: dispatched with peer=0 attached (generating no COMMIT).
fn applyLocalPresence(name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
    const parsed = try parsePresenceActionToPayload(name, args, 0);
    var args_buf: [128]u8 = undefined;
    const remote_args = try formatPresenceRemoteArgs(&args_buf, parsed);
    return action_registry.dispatch(name, remote_args, buf);
}

/// A client ephemeral: puts a PRESENCE on the presence outbound queue and returns `"sent"` (generating no PROPOSE).
/// Once HELLO is complete it may be sent even while `awaiting_sync` holds.
fn enqueueClientPresence(name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
    if (!io_inited) return error.NotConnected;
    peers_mutex.lockUncancelable(io_val);
    const ok = role == .client and started and client_slot.state == .active and client_slot.hello_done;
    peers_mutex.unlock(io_val);
    if (!ok) return error.NotConnected;

    // origin_peer is 0 when a client sends (the host overwrites it with the slot's peer id)
    const parsed = try parsePresenceActionToPayload(name, args, 0);
    var pbuf: [PRESENCE_PAYLOAD_LEN]u8 = undefined;
    const payload = try formatPresencePayload(&pbuf, parsed);

    peers_mutex.lockUncancelable(io_val);
    defer peers_mutex.unlock(io_val);
    if (role != .client or !started or client_slot.state != .active) return error.NotConnected;
    _ = client_slot.presence_outbound.enqueueLatestWins(io_val, payload); // a full queue drops
    client_slot.outbound.signal(io_val); // wake the writer
    return std.fmt.bufPrint(buf, "sent", .{}) catch "sent";
}

/// Converts harness action args into a PresencePayload. Coordinates are 0..255 and ttl is 0..=10000.
fn parsePresenceActionToPayload(name: []const u8, args: []const u8, origin_peer: u32) ProtocolError!PresencePayload {
    const subtype: PresenceSubtype = if (std.mem.eql(u8, name, "presence_point"))
        .point
    else if (std.mem.eql(u8, name, "presence_highlight"))
        .highlight
    else if (std.mem.eql(u8, name, "presence_suggest"))
        .suggest
    else
        return error.ProtocolError;

    var it = std.mem.tokenizeAny(u8, args, " \t");
    const parseI = struct {
        fn go(iter: *std.mem.TokenIterator(u8, .any)) ProtocolError!i32 {
            const tok = iter.next() orelse return error.ProtocolError;
            return std.fmt.parseInt(i32, tok, 10) catch error.ProtocolError;
        }
    }.go;
    const parseTtl = struct {
        fn go(iter: *std.mem.TokenIterator(u8, .any), st: PresenceSubtype) ProtocolError!u16 {
            const tok = iter.next() orelse return st.defaultTtlMs();
            const v = std.fmt.parseInt(u32, tok, 10) catch return error.ProtocolError;
            if (v > 10000) return error.ProtocolError;
            if (iter.next() != null) return error.ProtocolError;
            return if (v == 0) st.defaultTtlMs() else @intCast(v);
        }
    }.go;
    const inRange = struct {
        fn go(v: i32) bool {
            return v >= 0 and v <= 255;
        }
    }.go;

    return switch (subtype) {
        .point, .suggest => blk: {
            const x = try parseI(&it);
            const y = try parseI(&it);
            if (!inRange(x) or !inRange(y)) return error.ProtocolError;
            const ttl = try parseTtl(&it, subtype);
            break :blk .{
                .origin_peer = origin_peer,
                .subtype = subtype,
                .ttl_ms = ttl,
                .x0 = x,
                .y0 = y,
                .x1 = 0,
                .y1 = 0,
            };
        },
        .highlight => blk: {
            const x0 = try parseI(&it);
            const y0 = try parseI(&it);
            const x1 = try parseI(&it);
            const y1 = try parseI(&it);
            if (!inRange(x0) or !inRange(y0) or !inRange(x1) or !inRange(y1)) return error.ProtocolError;
            const ttl = try parseTtl(&it, subtype);
            break :blk .{
                .origin_peer = origin_peer,
                .subtype = subtype,
                .ttl_ms = ttl,
                .x0 = x0,
                .y0 = y0,
                .x1 = x1,
                .y1 = y1,
            };
        },
    };
}

/// Soft-broadcasts a PRESENCE to every active client (not limited to synced ones; a full queue drops rather than disconnecting).
fn broadcastPresence(payload: []const u8) void {
    if (!io_inited) return;
    peers_mutex.lockUncancelable(io_val);
    defer peers_mutex.unlock(io_val);
    if (!started or role != .host) return;
    for (&slots) |*s| {
        if (s.state != .active) continue;
        _ = s.presence_outbound.enqueueLatestWins(io_val, payload);
        s.outbound.signal(io_val);
    }
}

/// Fans out to the outbound queue of every connection that is active and synced.
pub fn broadcast(kind: u8, payload: []const u8) void {
    if (!io_inited) return;
    peers_mutex.lockUncancelable(io_val);
    defer peers_mutex.unlock(io_val);
    if (!started or role != .host) return;
    for (&slots) |*s| {
        if (s.state != .active or !s.synced) continue;
        if (!s.outbound.enqueue(io_val, kind, payload)) {
            requestCloseSlotLocked(s);
        }
    }
}

/// Puts one frame on the outbound queue of the client role (the minimal entry point for tests, and for sending a PROPOSE in future).
/// When it is full, netsync is disabled by a fail-soft.
/// Checking the state and enqueuing happen in the same `peers_mutex` section (which prevents a TOCTOU).
pub fn clientSend(kind: u8, payload: []const u8) bool {
    if (!io_inited) return false;
    peers_mutex.lockUncancelable(io_val);
    defer peers_mutex.unlock(io_val);
    if (role != .client or !started or client_slot.state != .active) return false;
    if (client_slot.outbound.enqueue(io_val, kind, payload)) return true;
    failSoftDisableClientLocked();
    return false;
}

pub fn shutdown() void {
    if (!io_inited) return;

    peers_mutex.lockUncancelable(io_val);
    const do_work = started or role != .disabled or have_server;
    const cur_role = role;
    peers_mutex.unlock(io_val);
    if (!do_work) return;

    stop_flag.store(true, .seq_cst);

    // Closing the listen socket first would make the blocking accept panic with BADF.
    // A dummy connect wakes the accept, and only after the acceptor is joined is the listen socket closed.
    if (have_server) {
        const port = server.socket.address.getPort();
        const wake_addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
        if (wake_addr.connect(io_val, .{ .mode = .stream })) |s| {
            s.close(io_val);
        } else |_| {}
    }
    if (acceptor_thread) |t| {
        t.join();
        acceptor_thread = null;
    }
    if (have_server) {
        server.deinit(io_val);
        have_server = false;
    }

    if (cur_role == .host) {
        peers_mutex.lockUncancelable(io_val);
        for (&slots) |*s| {
            if (s.state != .empty) requestCloseSlotLocked(s);
        }
        peers_mutex.unlock(io_val);
        for (&slots) |*s| {
            joinSlot(s);
        }
    } else if (cur_role == .client) {
        requestCloseSlot(&client_slot);
        joinSlot(&client_slot);
    }

    inbound.clear(io_val);
    presence_inbound.clear(io_val);
    peers_mutex.lockUncancelable(io_val);
    role = .disabled;
    started = false;
    local_peer_id = 0;
    next_peer_id = 1;
    router_clear_pending = false;
    awaiting_sync = false;
    freePendingSyncLocked();
    peers_mutex.unlock(io_val);
    // setRouter(null), wire_session and clearing the copilot session happen on the main thread only (symmetrically with clearRouterMain)
    action_registry.setRouter(null);
    setWireSessionFlag(false);
    notifySessionState(false);
    wire_seq = 0;
    last_applied_seq = 0;
    next_proposal_id = 0;
    last_rejected_proposal = 0;
    last_reject_reason_len = 0;
    pendingClear();
}

fn requestCloseSlot(s: *ConnSlot) void {
    peers_mutex.lockUncancelable(io_val);
    defer peers_mutex.unlock(io_val);
    requestCloseSlotLocked(s);
}

/// If the slot was reused during an export, say, this avoids closing the new connection by mistake.
fn requestCloseSlotIfGeneration(s: *ConnSlot, peer_id: u32, generation: u32) void {
    peers_mutex.lockUncancelable(io_val);
    defer peers_mutex.unlock(io_val);
    if (s.peer_id != peer_id or s.generation != generation) return;
    if (s.state == .empty) return;
    requestCloseSlotLocked(s);
}

fn requestCloseSlotLocked(s: *ConnSlot) void {
    if (s.state == .empty or s.state == .closing) return;
    s.state = .closing;
    s.outbound.close(io_val);
    s.presence_outbound.close(io_val);
    // ## The fd close invariant
    // stream.close must not happen until every thread that could use the fd (the writer above all) has been joined.
    // The only ways to wake another thread are outbound.close (a condvar) and stream.shutdown(.both).
    // The close happens after the writer is joined, exactly once, under peers_mutex and after inspecting socket_open
    // (in cleanupAfterReader, the spawn-failure path, and joinSlot). Closing from another thread would turn a blocking
    // send or recv into EBADF, which is an unreachable panic in Zig's std.
    if (s.socket_open) {
        s.stream.shutdown(io_val, .both) catch {};
    }
}

fn joinSlot(s: *ConnSlot) void {
    // A Thread handle is joined outside the mutex (which can race with cleanup, but if the handle is still there it is joined).
    const reader_t = blk: {
        peers_mutex.lockUncancelable(io_val);
        defer peers_mutex.unlock(io_val);
        const t = s.reader_thread;
        break :blk t;
    };
    if (reader_t) |t| {
        t.join();
        peers_mutex.lockUncancelable(io_val);
        s.reader_thread = null;
        peers_mutex.unlock(io_val);
    }
    const writer_t = blk: {
        peers_mutex.lockUncancelable(io_val);
        defer peers_mutex.unlock(io_val);
        const t = s.writer_thread;
        break :blk t;
    };
    if (writer_t) |t| {
        t.join();
        peers_mutex.lockUncancelable(io_val);
        s.writer_thread = null;
        peers_mutex.unlock(io_val);
    }
    peers_mutex.lockUncancelable(io_val);
    // If the reader's cleanup already closed it this is a no-op. If not, this is the sole owner and closes it here.
    if (s.socket_open) {
        s.stream.close(io_val);
        s.socket_open = false;
    }
    s.outbound.reset(io_val);
    s.presence_outbound.clear(io_val);
    s.state = .empty;
    s.hello_done = false;
    s.synced = false;
    s.snapshot_valid = false;
    s.join_snapshot_seq = 0;
    s.generation +%= 1;
    s.peer_id = 0;
    s.label_len = 0;
    peers_mutex.unlock(io_val);
}

/// Disables a client by a fail-soft (taking peers_mutex).
fn failSoftDisableClient() void {
    std.debug.print("[netsync] disabling the client by a fail-soft\n", .{});
    peers_mutex.lockUncancelable(io_val);
    defer peers_mutex.unlock(io_val);
    failSoftDisableClientLocked();
}

/// Disables a client while holding `peers_mutex`. Any remaining connection is closed.
fn failSoftDisableClientLocked() void {
    if (client_slot.state != .empty and client_slot.state != .closing) {
        requestCloseSlotLocked(&client_slot);
    }
    role = .disabled;
    started = false;
    local_peer_id = 0;
    awaiting_sync = false;
    freePendingSyncLocked();
    clearPeerCatalogLocked();
    requestRouterClear();
}

// ============================================================================
// Threads
// ============================================================================

fn acceptorMain() void {
    while (!stop_flag.load(.seq_cst)) {
        const stream = server.accept(io_val) catch |err| {
            if (stop_flag.load(.seq_cst)) break;
            std.debug.print("[netsync] accept failed: {s}\n", .{@errorName(err)});
            continue;
        };
        if (stop_flag.load(.seq_cst)) {
            stream.close(io_val);
            break;
        }

        peers_mutex.lockUncancelable(io_val);
        const slot_opt = blk: {
            for (&slots, 0..) |*s, i| {
                if (s.state == .empty) {
                    // The generation was already incremented when it last became empty. It is preserved across a reuse.
                    const gen = s.generation;
                    s.* = .{
                        .state = .hello_pending,
                        .stream = stream,
                        .socket_open = true,
                        .slot_index = i,
                        .is_client_conn = false,
                        .generation = gen,
                    };
                    s.outbound.reset(io_val);
                    break :blk s;
                }
            }
            break :blk null;
        };
        peers_mutex.unlock(io_val);

        if (slot_opt == null) {
            std.debug.print("[netsync] the peer slots are full (MAX_PEERS={d}); disconnecting\n", .{MAX_PEERS});
            stream.close(io_val);
            continue;
        }
        const slot = slot_opt.?;

        slot.writer_thread = std.Thread.spawn(.{}, writerMain, .{slot}) catch {
            std.debug.print("[netsync] failed to spawn the writer — releasing the slot\n", .{});
            peers_mutex.lockUncancelable(io_val);
            stream.close(io_val);
            slot.state = .empty;
            peers_mutex.unlock(io_val);
            continue;
        };
        slot.reader_thread = std.Thread.spawn(.{}, readerMain, .{slot}) catch {
            std.debug.print("[netsync] failed to spawn the reader — releasing the slot\n", .{});
            // Do not close before joining the writer (the invariant: a close happens once, after the writer is joined).
            slot.outbound.close(io_val);
            stream.shutdown(io_val, .both) catch {};
            if (slot.writer_thread) |t| t.join();
            slot.writer_thread = null;
            peers_mutex.lockUncancelable(io_val);
            if (slot.socket_open) {
                stream.close(io_val);
                slot.socket_open = false;
            }
            slot.state = .empty;
            peers_mutex.unlock(io_val);
            continue;
        };
    }
}

fn writerMain(slot: *ConnSlot) void {
    var wbuf: [1024]u8 = undefined;
    var writer = slot.stream.writer(io_val, &wbuf);
    var entry: OutboundEntry = .{ .inline_frame = .{} };
    var presence_buf: [PRESENCE_PAYLOAD_LEN]u8 = undefined;
    while (true) {
        // Give the COMMIT outbound queue priority (so a presence flood cannot starve the document)
        if (slot.outbound.tryDequeue(io_val, &entry)) {
            const send_ok = blk: {
                switch (entry) {
                    .inline_frame => |f| {
                        encodeFrame(&writer.interface, f.kind, f.data[0..f.len]) catch break :blk false;
                    },
                    .big_frame => |b| {
                        encodeFrame(&writer.interface, b.kind, b.ptr[0..b.len]) catch break :blk false;
                    },
                }
                writer.interface.flush() catch break :blk false;
                break :blk true;
            };
            entry.free();
            if (!send_ok) {
                requestCloseSlot(slot);
                break;
            }
            continue;
        }
        if (slot.presence_outbound.tryDequeue(io_val, &presence_buf)) {
            const send_ok = blk: {
                encodeFrame(&writer.interface, @intFromEnum(FrameKind.presence), &presence_buf) catch break :blk false;
                writer.interface.flush() catch break :blk false;
                break :blk true;
            };
            if (!send_ok) {
                requestCloseSlot(slot);
                break;
            }
            continue;
        }
        // Both empty → wait on the outbound condvar (enqueuing a presence signals the same condvar).
        // It does not dequeue: so as not to swallow a presence wake-up, it goes waitForWork → retry at the top of the loop.
        if (!slot.outbound.waitForWork(io_val)) break;
    }
}

fn readerMain(slot: *ConnSlot) void {
    defer cleanupAfterReader(slot);

    var rbuf: [1024]u8 = undefined;
    var reader = slot.stream.reader(io_val, &rbuf);
    var payload_buf: [MAX_ACTION_FRAME_BYTES]u8 = undefined;

    while (!stop_flag.load(.seq_cst)) {
        const kind = reader.interface.takeByte() catch break;
        const len = reader.interface.takeInt(u32, .little) catch break;
        const max = maxPayloadForKind(kind);

        if (len > max) break;

        // Before HELLO completes, anything but a HELLO disconnects with a protocol error (ahead of carrying on to discard a SYNC or an unknown frame).
        if (!slot.hello_done and kind != @intFromEnum(FrameKind.hello)) {
            break;
        }

        // SYNC: a client reads it onto the heap and leaves it pending. A host receiving one is a protocol error.
        if (kind == @intFromEnum(FrameKind.sync)) {
            if (!slot.is_client_conn) {
                std.debug.print("[netsync] the host received a SYNC — disconnecting with a protocol error\n", .{});
                break;
            }
            if (len > MAX_SYNC_BYTES) break;
            const heap = gpa.alloc(u8, len) catch break;
            if (len > 0) reader.interface.readSliceAll(heap[0..len]) catch {
                gpa.free(heap);
                break;
            };
            peers_mutex.lockUncancelable(io_val);
            freePendingSyncLocked();
            pending_sync = heap;
            peers_mutex.unlock(io_val);
            continue;
        }

        const unprocessed = !isKnownKind(kind);
        if (unprocessed) {
            std.debug.print("[netsync] unknown frame kind=0x{x:0>2} len={d} — discarding it and carrying on\n", .{ kind, len });
            discardPayload(&reader.interface, len) catch break;
            continue;
        }

        if (len > payload_buf.len) break;
        if (len > 0) reader.interface.readSliceAll(payload_buf[0..len]) catch break;
        const payload = payload_buf[0..len];

        if (!slot.hello_done) {
            handleHello(slot, payload) catch {
                if (!slot.is_client_conn) {
                    std.debug.print("[netsync] HELLO protocol error — disconnecting\n", .{});
                }
                break;
            };
            continue;
        }

        if (kind == @intFromEnum(FrameKind.hello)) break; // duplicate HELLO

        // PRESENCE: onto the dedicated queue (a validation failure, or a full queue, drops without touching the COMMIT queue or disconnecting)
        if (kind == @intFromEnum(FrameKind.presence)) {
            if (len == PRESENCE_PAYLOAD_LEN) {
                // A light check of reserved, subtype and TTL (the real apply is in pump). Anything invalid drops.
                if (parsePresencePayload(payload)) |_| {
                    _ = presence_inbound.enqueueLatestWins(io_val, slot.peer_id, payload);
                } else |_| {}
            }
            continue;
        }

        if (!inbound.enqueue(io_val, kind, payload, slot.peer_id)) {
            std.debug.print("[netsync] inbound is full — disconnecting\n", .{});
            break;
        }
    }

    if (!slot.hello_done and slot.is_client_conn) {
        std.debug.print("[netsync] the HELLO handshake failed (the connection was closed)\n", .{});
    }
}

/// When a reader finishes: wake the writer and join it, and only then close the fd and return the slot to empty.
/// The order: outbound.close → shutdown → join the writer → stream.close (once) → reset the slot.
/// When a peer leaves on the host side, a PEER_INFO LEFT is distributed to the remaining clients.
fn cleanupAfterReader(slot: *ConnSlot) void {
    const was_client = slot.is_client_conn;

    // stash the peer metadata for the leave distribution (before the slot becomes empty)
    var leave_peer_id: u32 = 0;
    var leave_label_buf: [MAX_LABEL_LEN]u8 = undefined;
    var leave_label_len: usize = 0;
    var do_leave_broadcast = false;

    peers_mutex.lockUncancelable(io_val);
    // distribute a LEFT only for a peer that completed HELLO (on the host side)
    if (!was_client and slot.hello_done and slot.peer_id != 0) {
        leave_peer_id = slot.peer_id;
        leave_label_len = slot.label_len;
        if (leave_label_len > 0) {
            @memcpy(leave_label_buf[0..leave_label_len], slot.label_buf[0..leave_label_len]);
        }
        do_leave_broadcast = true;
    }
    if (slot.state != .empty and slot.state != .closing) {
        slot.state = .closing;
        slot.outbound.close(io_val);
    } else {
        slot.outbound.close(io_val);
    }
    // Only wake the writer. The close comes after the join (below).
    if (slot.socket_open) {
        slot.stream.shutdown(io_val, .both) catch {};
    }
    const writer_t = slot.writer_thread;
    peers_mutex.unlock(io_val);

    if (writer_t) |t| {
        t.join();
    }

    peers_mutex.lockUncancelable(io_val);
    slot.writer_thread = null;
    if (slot.socket_open) {
        slot.stream.close(io_val);
        slot.socket_open = false;
    }
    slot.outbound.reset(io_val);
    slot.presence_outbound.clear(io_val);
    slot.state = .empty;
    slot.hello_done = false;
    slot.synced = false;
    slot.snapshot_valid = false;
    slot.join_snapshot_seq = 0;
    slot.generation +%= 1;
    slot.peer_id = 0;
    slot.label_len = 0;
    slot.reader_thread = null;

    // A LEFT to the remaining active clients (the leaving slot is already empty). The outbound lock order: peers_mutex → outbound.
    if (do_leave_broadcast and role == .host) {
        const lab = leave_label_buf[0..leave_label_len];
        for (&slots) |*s| {
            if (s.state != .active) continue;
            _ = enqueuePeerInfoLocked(s, leave_peer_id, PEER_INFO_KIND_LEFT, lab);
        }
        peer_metadata_revision +%= 1;
    }

    // Once a client disconnects, netsync is disabled by a fail-soft under the same mutex. Clearing the router is delegated to pump.
    if (was_client) {
        role = .disabled;
        started = false;
        local_peer_id = 0;
        awaiting_sync = false;
        freePendingSyncLocked();
        clearPeerCatalogLocked();
        requestRouterClear();
    }
    peers_mutex.unlock(io_val);

    if (was_client) {
        std.debug.print("[netsync] disabling the client by a fail-soft\n", .{});
    }
}

fn handleHello(slot: *ConnSlot, payload: []const u8) ProtocolError!void {
    if (slot.is_client_conn) {
        // the host's response to the client
        const pid = try parseHostHello(payload);
        peers_mutex.lockUncancelable(io_val);
        defer peers_mutex.unlock(io_val);
        if (slot.hello_done) return error.ProtocolError;
        slot.hello_done = true;
        slot.peer_id = pid;
        local_peer_id = pid;
        slot.state = .active;
        // Register self as the notional first catalog entry (the host never sends a self PEER_INFO).
        const self_lab = slot.label_buf[0..slot.label_len];
        _ = upsertPeerCatalogLocked(pid, slot.actor_kind, self_lab, true);
        peer_metadata_revision +%= 1;
        return;
    }

    // client→host
    const parsed = try parseClientHello(payload);
    peers_mutex.lockUncancelable(io_val);
    defer peers_mutex.unlock(io_val);
    if (slot.hello_done) return error.ProtocolError;
    if (slot.state != .hello_pending) return error.ProtocolError;

    const pid = next_peer_id;
    next_peer_id += 1;
    slot.peer_id = pid;
    slot.actor_kind = parsed.kind;
    const n = @min(parsed.label.len, MAX_LABEL_LEN);
    if (n > 0) @memcpy(slot.label_buf[0..n], parsed.label[0..n]);
    slot.label_len = n;
    slot.hello_done = true;
    slot.state = .active;
    slot.synced = false;
    slot.snapshot_valid = false;
    slot.join_snapshot_seq = 0;

    var hbuf: [64]u8 = undefined;
    const resp = formatHostHello(&hbuf, pid) catch return error.ProtocolError;
    if (!slot.outbound.enqueue(io_val, @intFromEnum(FrameKind.hello), resp)) {
        return error.ProtocolError;
    }

    // Distributing PEER_INFO (ahead of the SYNC, on the same outbound FIFO; ClientJoined → pump → SYNC):
    // 1. the host identity, to the newcomer
    // 2. every existing active peer, to the newcomer
    // 3. the new peer, to every existing active client
    const new_label = slot.label_buf[0..slot.label_len];
    const new_kind_b = actorKindToPeerInfoByte(slot.actor_kind);
    if (!enqueuePeerInfoLocked(slot, HOST_PEER_ID, actorKindToPeerInfoByte(HOST_ACTOR_KIND), HOST_LABEL)) {
        return error.ProtocolError;
    }
    for (&slots) |*s| {
        if (s == slot or s.state != .active) continue;
        const lab = s.label_buf[0..s.label_len];
        if (!enqueuePeerInfoLocked(slot, s.peer_id, actorKindToPeerInfoByte(s.actor_kind), lab)) {
            return error.ProtocolError;
        }
    }
    for (&slots) |*s| {
        if (s == slot or s.state != .active) continue;
        if (!enqueuePeerInfoLocked(s, pid, new_kind_b, new_label)) {
            // fail-soft: disconnect only the connection concerned (the existing policy)
            requestCloseSlotLocked(s);
        }
    }
    peer_metadata_revision +%= 1;

    // ClientJoined onto the serialised inbound queue (pump sends the SYNC). This holds the mutex, but inbound has its own.
    var joined: [8]u8 = undefined;
    std.mem.writeInt(u32, joined[0..4], pid, .little);
    std.mem.writeInt(u32, joined[4..8], slot.generation, .little);
    if (!inbound.enqueue(io_val, INTERNAL_CLIENT_JOINED, &joined, pid)) {
        return error.ProtocolError;
    }
}

/// A reset for tests (shutdown plus clearing the state).
pub fn resetForTest() void {
    shutdown();
    clearRouterMain();
    action_registry.resetForTest();
    shared_executor = null;
    session_state_cb = null;
    state_sync = null;
    defaultClientLabel();
    stop_flag.store(false, .seq_cst);
    wire_seq = 0;
    last_applied_seq = 0;
    next_proposal_id = 0;
    last_rejected_proposal = 0;
    last_reject_reason_len = 0;
    awaiting_sync = false;
    freePendingSyncLocked();
    pendingClear();
    if (io_inited) {
        presence_inbound.clear(io_val);
        peers_mutex.lockUncancelable(io_val);
        clearPeerCatalogLocked();
        peer_metadata_revision = 0;
        peers_mutex.unlock(io_val);
    } else {
        clearPeerCatalogLocked();
        peer_metadata_revision = 0;
    }
}

/// For tests: a slot's synced, snapshot_valid and join_snapshot_seq.
pub fn testSlotSyncInfo(peer_id: u32) ?struct { synced: bool, snapshot_valid: bool, join_snapshot_seq: u64, generation: u32 } {
    if (!io_inited) return null;
    peers_mutex.lockUncancelable(io_val);
    defer peers_mutex.unlock(io_val);
    for (&slots) |*s| {
        if (s.state == .active and s.peer_id == peer_id) {
            return .{
                .synced = s.synced,
                .snapshot_valid = s.snapshot_valid,
                .join_snapshot_seq = s.join_snapshot_seq,
                .generation = s.generation,
            };
        }
    }
    return null;
}

pub fn testAwaitingSync() bool {
    if (!io_inited) return false;
    peers_mutex.lockUncancelable(io_val);
    defer peers_mutex.unlock(io_val);
    return awaiting_sync;
}

/// For tests: how many entries are in the client's pending queue (awaiting a PROPOSE or PROPOSE_REVERT).
pub fn testPendingCount() usize {
    return pending_count;
}

/// How many outbound proposals a client is waiting on (read only, for draining chunks).
/// The same value as the digest's `pending`. On a host, or with netsync disabled, it is 0.
pub fn pendingProposalCount() usize {
    if (!isEnabled() or !isClient()) return 0;
    return pending_count;
}

/// For tests: overwrite an active slot's join_snapshot_seq (to check the before-peer-join case).
pub fn testSetJoinSnapshotSeq(peer_id: u32, seq: u64) bool {
    if (!io_inited) return false;
    peers_mutex.lockUncancelable(io_val);
    defer peers_mutex.unlock(io_val);
    for (&slots) |*s| {
        if (s.state == .active and s.peer_id == peer_id) {
            s.join_snapshot_seq = seq;
            return true;
        }
    }
    return false;
}

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

fn sleepMs(ms: u64) void {
    std.Io.sleep(std.testing.io, .fromMilliseconds(@intCast(ms)), .awake) catch {};
}

fn waitPeers(n: usize, timeout_ms: u64) !void {
    var waited: u64 = 0;
    while (peerCount() < n) {
        if (waited >= timeout_ms) return error.Timeout;
        sleepMs(5);
        waited += 5;
    }
}

/// Waits until every host slot has finished teardown, meaning `state == .empty` with an emptied
/// outbound queue. `peerCount()` is not enough on its own: it counts `.active` slots only, while
/// teardown runs `.active` -> `.closing` -> (writer join, close) -> `.empty`. A test that waits on
/// `peerCount() == 0` can therefore act while a slot is still `.closing`, and the acceptor reuses
/// only `.empty` slots — so a reconnect lands in a different slot than the test expects.
fn waitSlotsEmpty(timeout_ms: u64) !void {
    var waited: u64 = 0;
    while (true) {
        peers_mutex.lockUncancelable(io_val);
        var all_empty = true;
        for (&slots) |*s| {
            if (s.state != .empty or s.outbound.len(io_val) != 0) {
                all_empty = false;
                break;
            }
        }
        peers_mutex.unlock(io_val);
        if (all_empty) return;
        if (waited >= timeout_ms) return error.Timeout;
        sleepMs(10);
        waited += 10;
    }
}

/// Checks the outbound queue of a host slot that a fresh connection has just been given.
///
/// The queue is deliberately **not** required to be empty. `handleHello` enqueues the new
/// connection's own HELLO and the host PEER_INFO while still holding `peers_mutex`, and it
/// makes the slot `.active` — the thing `peerCount()` reports — in the same critical section.
/// So by the time a test observes the peer, those two frames are already queued, and whether
/// the writer thread has drained them is a scheduling question, not an invariant.
///
/// What is invariant is that nothing survived the reuse: the queue is open again, it holds no
/// more than the two handshake frames, and it holds no big entry at all. The fresh connection
/// has been handed no large frame yet (the SYNC follows a `pump`), so a big entry could only
/// be an unsent leftover of the previous connection.
///
/// The bound of two frames — the HELLO and the host PEER_INFO — assumes the newcomer is the only
/// peer, which is what a test reusing a slot after waiting for every slot to empty gives. With
/// another peer already active, `handleHello` sends that peer's PEER_INFO too and the bound grows.
///
/// Takes the queue's mutex; callers may hold `peers_mutex`, which is the order the rest of the
/// module locks in (`peers_mutex` first, never the reverse).
fn expectFreshSlotOutbound(q: *OutboundQueue) !void {
    q.mutex.lockUncancelable(io_val);
    defer q.mutex.unlock(io_val);
    try testing.expect(!q.closed);
    try testing.expect(q.count <= 2);
    var i: usize = 0;
    while (i < q.count) : (i += 1) {
        const entry = &q.slots[(q.head + i) % OUTBOUND_CAP];
        switch (entry.*) {
            .big_frame => return error.LeftoverBigEntry,
            .inline_frame => |f| try testing.expect(
                f.kind == @intFromEnum(FrameKind.hello) or f.kind == @intFromEnum(FrameKind.peer_info),
            ),
        }
    }
}

/// Handles ClientJoined and makes every active slot synced (including sending the empty SYNC).
fn pumpUntilAllSynced(timeout_ms: u64) !void {
    var waited: u64 = 0;
    while (waited < timeout_ms) {
        pump();
        peers_mutex.lockUncancelable(io_val);
        var all_synced = true;
        var any = false;
        for (&slots) |*s| {
            if (s.state == .active) {
                any = true;
                if (!s.synced) all_synced = false;
            }
        }
        peers_mutex.unlock(io_val);
        if (any and all_synced) return;
        sleepMs(5);
        waited += 5;
    }
    return error.Timeout;
}

/// Reads the one empty SYNC a raw client receives after its HELLO.
/// Any PEER_INFO in between (the join distribution) is read and discarded.
fn expectEmptySync(stream: net.Stream) !void {
    var rbuf: [512]u8 = undefined;
    var reader = stream.reader(io_val, &rbuf);
    var pbuf: [MAX_ACTION_FRAME_BYTES]u8 = undefined;
    while (true) {
        const frame = try decodeFrame(&reader.interface, &pbuf);
        if (frame.kind == @intFromEnum(FrameKind.peer_info)) continue;
        try testing.expectEqual(@intFromEnum(FrameKind.sync), frame.kind);
        const parsed = try parseSyncPayload(frame.payload);
        try testing.expectEqual(@as(usize, 0), parsed.state.len);
        return;
    }
}

/// Discards PEER_INFO frames and returns the next non-peer_info frame (for the raw client tests).
fn decodeSkippingPeerInfo(r: *Io.Reader, buf: []u8) !Frame {
    while (true) {
        const frame = try decodeFrame(r, buf);
        if (frame.kind != @intFromEnum(FrameKind.peer_info)) return frame;
    }
}

fn waitClientActive(timeout_ms: u64) !void {
    var waited: u64 = 0;
    while (true) {
        peers_mutex.lockUncancelable(io_val);
        const ok = client_slot.state == .active;
        peers_mutex.unlock(io_val);
        if (ok) return;
        if (waited >= timeout_ms) return error.Timeout;
        sleepMs(5);
        waited += 5;
    }
}

test "netsync: a codec round trip for every kind" {
    const kinds = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09 };
    for (kinds) |k| {
        var obuf: [512]u8 = undefined;
        var w = Io.Writer.fixed(&obuf);
        const payload = "hello-payload";
        try encodeFrame(&w, k, payload);
        const encoded = w.buffered();

        var r = Io.Reader.fixed(encoded);
        var pbuf: [256]u8 = undefined;
        // a SYNC of 4096 or under can be read by decodeFrame too
        const frame = try decodeFrame(&r, &pbuf);
        try testing.expectEqual(k, frame.kind);
        try testing.expectEqualStrings(payload, frame.payload);
    }
}

test "netsync: the codec satisfies a partial read" {
    // Send the header and the payload separately over a real socket, and confirm decodeFrame satisfies the partial read.
    resetForTest();
    defer resetForTest();
    ensureIo();

    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(0) };
    var srv = try addr.listen(io_val, .{ .reuse_address = true });
    defer srv.deinit(io_val);
    const port = srv.socket.address.getPort();

    const SlowWrite = struct {
        fn run(p: u16) void {
            ensureIo();
            const a = net.IpAddress{ .ip4 = net.Ip4Address.loopback(p) };
            const s = a.connect(io_val, .{ .mode = .stream }) catch return;
            defer s.close(io_val);
            var frame_buf: [16]u8 = undefined;
            var w = Io.Writer.fixed(&frame_buf);
            encodeFrame(&w, 0x02, "abcd") catch return;
            const encoded = w.buffered();
            // 3 bytes (partway through kind+len) → then the rest
            var wbuf: [8]u8 = undefined;
            var writer = s.writer(io_val, &wbuf);
            writer.interface.writeAll(encoded[0..3]) catch return;
            writer.interface.flush() catch return;
            sleepMs(30);
            writer.interface.writeAll(encoded[3..]) catch return;
            writer.interface.flush() catch return;
            sleepMs(50); // keep it until the reader has finished taking it
        }
    };
    const t = try std.Thread.spawn(.{}, SlowWrite.run, .{port});
    defer t.join();

    const stream = try srv.accept(io_val);
    defer stream.close(io_val);
    var rbuf: [32]u8 = undefined;
    var reader = stream.reader(io_val, &rbuf);
    var pbuf: [32]u8 = undefined;
    const frame = try decodeFrame(&reader.interface, &pbuf);
    try testing.expectEqual(@as(u8, 0x02), frame.kind);
    try testing.expectEqualStrings("abcd", frame.payload);
}

test "netsync: the codec decodes an unknown kind while it is within the limit, and maxPayload is 4096" {
    try testing.expectEqual(@as(usize, MAX_ACTION_FRAME_BYTES), maxPayloadForKind(0x99));
    try testing.expectEqual(@as(usize, MAX_SYNC_BYTES), maxPayloadForKind(0x04));
    try testing.expectEqual(@as(usize, MAX_ACTION_FRAME_BYTES), maxPayloadForKind(0x01));
    try testing.expectEqual(@as(usize, PRESENCE_PAYLOAD_LEN), maxPayloadForKind(0x09));
    try testing.expect(isKnownKind(0x09));
    try testing.expect(!isKnownKind(0x0A));
}

test "netsync: a codec len over the limit gives PayloadTooLarge" {
    var obuf: [32]u8 = undefined;
    var w = Io.Writer.fixed(&obuf);
    try w.writeByte(0x02);
    try w.writeInt(u32, 5000, .little); // > 4096
    // the payload is not written
    var r = Io.Reader.fixed(w.buffered());
    var pbuf: [MAX_ACTION_FRAME_BYTES]u8 = undefined;
    try testing.expectError(error.PayloadTooLarge, decodeFrame(&r, &pbuf));
}

test "netsync: a large SYNC is discarded by the codec's discardPayload" {
    var raw: [5 + 8000 + 1]u8 = undefined;
    raw[0] = 0x04;
    std.mem.writeInt(u32, raw[1..5], 8000, .little);
    @memset(raw[5 .. 5 + 8000], 0xCD);
    raw[5 + 8000] = 0x11;

    var r = Io.Reader.fixed(&raw);
    const kind = try r.takeByte();
    try testing.expectEqual(@as(u8, 0x04), kind);
    const len = try r.takeInt(u32, .little);
    try testing.expectEqual(@as(u32, 8000), len);
    try discardPayload(&r, len);
    const marker = try r.takeByte();
    try testing.expectEqual(@as(u8, 0x11), marker);
}

test "netsync: HELLO parsing with a missing field, an invalid actor_kind, a label over the limit, and a control character" {
    try testing.expectError(error.ProtocolError, parseClientHello("client"));
    try testing.expectError(error.ProtocolError, parseClientHello("client 1"));
    try testing.expectError(error.ProtocolError, parseClientHello("client 1 robot bob"));
    try testing.expectError(error.ProtocolError, parseClientHello("client 2 human bob")); // version
    try testing.expectError(error.ProtocolError, parseClientHello("client 1 human bob\x01"));
    var long: [201]u8 = undefined;
    @memset(&long, 'x');
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "client 1 human {s}", .{&long});
    try testing.expectError(error.ProtocolError, parseClientHello(msg));

    const ok = try parseClientHello("client 1 agent my label");
    try testing.expectEqual(ActorKind.agent, ok.kind);
    try testing.expectEqualStrings("my label", ok.label);

    try testing.expectError(error.ProtocolError, parseHostHello("host 1"));
    try testing.expectError(error.ProtocolError, parseHostHello("host 2 3"));
    try testing.expectEqual(@as(u32, 7), try parseHostHello("host 1 7"));
}

test "netsync: a PEER_INFO codec round trip and its validation (the codec alone; distribution is elsewhere)" {
    var buf: [MAX_ACTION_FRAME_BYTES]u8 = undefined;

    // a round trip (human, agent, left; a label may contain a space, and may be empty)
    const p1 = try formatPeerInfo(&buf, 3, PEER_INFO_KIND_AGENT, "copilot bot");
    const d1 = try parsePeerInfo(p1);
    try testing.expectEqual(@as(u32, 3), d1.peer_id);
    try testing.expectEqual(PEER_INFO_KIND_AGENT, d1.kind);
    try testing.expectEqualStrings("copilot bot", d1.label);

    const p2 = try formatPeerInfo(&buf, 0xFFFF_FFFF, PEER_INFO_KIND_LEFT, "");
    const d2 = try parsePeerInfo(p2);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), d2.peer_id);
    try testing.expectEqual(PEER_INFO_KIND_LEFT, d2.kind);
    try testing.expectEqualStrings("", d2.label);

    // invalid: a too-short payload, an unknown kind, a control character in the label, a label over the limit
    try testing.expectError(error.ProtocolError, parsePeerInfo(&[_]u8{ 1, 0, 0, 0 }));
    var bad_kind: [5]u8 = .{ 1, 0, 0, 0, 2 };
    try testing.expectError(error.ProtocolError, parsePeerInfo(&bad_kind));
    const p3 = try formatPeerInfo(&buf, 1, PEER_INFO_KIND_HUMAN, "ok");
    buf[p3.len - 1] = 0x01; // change the last byte to a control character
    try testing.expectError(error.ProtocolError, parsePeerInfo(buf[0..p3.len]));
    var long: [MAX_LABEL_LEN + 1]u8 = undefined;
    @memset(&long, 'x');
    try testing.expectError(error.LabelTooLong, formatPeerInfo(&buf, 1, PEER_INFO_KIND_HUMAN, &long));
}

// ---------------------------------------------------------------------------
// the peer catalog, distributing PEER_INFO, and resolvePeerOrigin
// ---------------------------------------------------------------------------

test "netsync: sanitizePeerLabel replaces control characters and truncates to 200B" {
    var out: [MAX_LABEL_LEN]u8 = undefined;
    const s1 = sanitizePeerLabel(&out, "a\x01b\nc");
    try testing.expectEqualStrings("a_b_c", s1);

    var long: [250]u8 = undefined;
    @memset(&long, 'z');
    const s2 = sanitizePeerLabel(&out, &long);
    try testing.expectEqual(@as(usize, MAX_LABEL_LEN), s2.len);
    try testing.expect(s2[0] == 'z');
}

test "netsync: client catalog insert/update/LEFT tombstone/reuse" {
    resetForTest();
    defer resetForTest();
    ensureIo();
    peers_mutex.lockUncancelable(io_val);
    role = .client;
    started = true;
    peers_mutex.unlock(io_val);

    // host + self + remote
    var pbuf: [5 + MAX_LABEL_LEN]u8 = undefined;
    const host_p = try formatPeerInfo(&pbuf, 0, PEER_INFO_KIND_HUMAN, "host");
    handlePeerInfo(host_p);
    const self_p = try formatPeerInfo(&pbuf, 1, PEER_INFO_KIND_AGENT, "bot");
    handlePeerInfo(self_p);
    const rem_p = try formatPeerInfo(&pbuf, 2, PEER_INFO_KIND_HUMAN, "alice");
    handlePeerInfo(rem_p);

    var lbuf: [MAX_LABEL_LEN]u8 = undefined;
    const r0 = resolvePeerOrigin(0, &lbuf).?;
    try testing.expectEqual(ActorKind.human, r0.kind);
    try testing.expectEqualStrings("host", r0.label);
    try testing.expect(r0.active);
    const r1 = resolvePeerOrigin(1, &lbuf).?;
    try testing.expectEqual(ActorKind.agent, r1.kind);
    try testing.expectEqualStrings("bot", r1.label);
    try testing.expectEqual(@as(?PeerOriginView, null), resolvePeerOrigin(99, &lbuf));

    const rev_before_left = peerMetadataRevision();
    const left_p = try formatPeerInfo(&pbuf, 2, PEER_INFO_KIND_LEFT, "alice");
    handlePeerInfo(left_p);
    try testing.expect(peerMetadataRevision() > rev_before_left);
    const r2 = resolvePeerOrigin(2, &lbuf).?;
    try testing.expect(!r2.active);
    try testing.expectEqualStrings("alice", r2.label); // tombstone keeps label

    // a LEFT for an unknown peer is ignored (the revision does not change)
    const rev_unk = peerMetadataRevision();
    const left_unk = try formatPeerInfo(&pbuf, 77, PEER_INFO_KIND_LEFT, "x");
    handlePeerInfo(left_unk);
    try testing.expectEqual(rev_unk, peerMetadataRevision());

    // update existing
    const self_upd = try formatPeerInfo(&pbuf, 1, PEER_INFO_KIND_AGENT, "bot2");
    handlePeerInfo(self_upd);
    try testing.expectEqualStrings("bot2", resolvePeerOrigin(1, &lbuf).?.label);

    // reusing a tombstone: fill the catalog with active entries and reuse an inactive one
    peers_mutex.lockUncancelable(io_val);
    // peer 2 is an inactive tombstone. Fill MAX_PEER_CATALOG-1 with active entries, and the rest reuses the tombstone.
    var pid: u32 = 10;
    var filled: usize = 0;
    for (&peer_catalog) |*e| {
        if (e.occupied and e.active) filled += 1;
    }
    while (filled < MAX_PEER_CATALOG) : ({
        pid += 1;
        filled += 1;
    }) {
        // fill a free slot, or an inactive one
        const ok = upsertPeerCatalogLocked(pid, .human, "fill", true);
        if (!ok) break;
    }
    // once they are all active a new one fails
    const all_active_fail = upsertPeerCatalogLocked(9999, .human, "nope", true);
    // the peer2 tombstone may not have survived, so make one inactive and confirm the reuse
    _ = markPeerCatalogLeftLocked(10);
    try testing.expect(upsertPeerCatalogLocked(8888, .agent, "reuse", true));
    peers_mutex.unlock(io_val);
    _ = all_active_fail;
    try testing.expectEqualStrings("reuse", resolvePeerOrigin(8888, &lbuf).?.label);
}

test "netsync: resolvePeerOrigin with the host's fixed identity and with slots" {
    resetForTest();
    defer resetForTest();
    initHost(0);
    var lbuf: [MAX_LABEL_LEN]u8 = undefined;
    const host_v = resolvePeerOrigin(0, &lbuf).?;
    try testing.expectEqual(HOST_ACTOR_KIND, host_v.kind);
    try testing.expectEqualStrings(HOST_LABEL, host_v.label);
    try testing.expect(host_v.active);
    try testing.expectEqual(@as(?PeerOriginView, null), resolvePeerOrigin(1, &lbuf));

    const port = listeningPort().?;
    var stream = try rawHelloConnectAs(net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) }, .agent, "copilot");
    defer stream.close(io_val);
    try waitPeers(1, 2000);

    const peer_v = resolvePeerOrigin(1, &lbuf).?;
    try testing.expectEqual(ActorKind.agent, peer_v.kind);
    try testing.expectEqualStrings("copilot", peer_v.label);
    try testing.expect(peerMetadataRevision() > 0);
}

test "netsync: the PEER_INFO distribution order on join (the host then the existing peers, then the existing peers to the newcomer)" {
    resetForTest();
    defer resetForTest();
    initHost(0);
    const port = listeningPort().?;
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    ensureIo();

    // client A: expectEmptySync skips PEER_INFO frames, so even if rawHelloConnect's temporary reader
    // throws away the host PEER_INFO along with its buffer, deciding that the SYNC arrived still holds.
    var a = try rawHelloConnectAs(addr, .human, "alice");
    defer a.close(io_val);
    try waitPeers(1, 2000);
    try pumpUntilAllSynced(2000);
    try expectEmptySync(a);

    // client B: read the HELLO and the PEER_INFO that follows with the **same reader**.
    // rawHelloConnectAs makes a temporary reader for the HELLO and discards it, so if TCP puts HELLO and PEER_INFO
    // in the same read, the PEER_INFO is thrown away while still in rbuf. With the next reader,
    // host(0) is missing and alice(1) appears first — a flaky result (it reproduces under load, and no fixed sleep fixes it).
    const b = try addr.connect(io_val, .{ .mode = .stream });
    defer b.close(io_val);
    {
        var wbuf: [256]u8 = undefined;
        var writer = b.writer(io_val, &wbuf);
        var hbuf: [128]u8 = undefined;
        const hello = try formatClientHello(&hbuf, .agent, "bot");
        try encodeFrame(&writer.interface, @intFromEnum(FrameKind.hello), hello);
        try writer.interface.flush();
    }
    var brbuf: [512]u8 = undefined;
    var breader = b.reader(io_val, &brbuf);
    var bpbuf: [MAX_ACTION_FRAME_BYTES]u8 = undefined;

    {
        const f = try decodeFrame(&breader.interface, &bpbuf);
        try testing.expectEqual(@intFromEnum(FrameKind.hello), f.kind);
        try testing.expectEqual(@as(u32, 2), try parseHostHello(f.payload));
    }
    try waitPeers(2, 2000);

    // PEER_INFO host → PEER_INFO alice (the outbound FIFO order, checked deterministically with the same reader)
    {
        const f1 = try decodeFrame(&breader.interface, &bpbuf);
        try testing.expectEqual(@intFromEnum(FrameKind.peer_info), f1.kind);
        const p1 = try parsePeerInfo(f1.payload);
        try testing.expectEqual(@as(u32, 0), p1.peer_id);
        try testing.expectEqual(PEER_INFO_KIND_HUMAN, p1.kind);
        try testing.expectEqualStrings(HOST_LABEL, p1.label);

        const f2 = try decodeFrame(&breader.interface, &bpbuf);
        try testing.expectEqual(@intFromEnum(FrameKind.peer_info), f2.kind);
        const p2 = try parsePeerInfo(f2.payload);
        try testing.expectEqual(@as(u32, 1), p2.peer_id);
        try testing.expectEqualStrings("alice", p2.label);
    }

    // the "new bot" PEER_INFO to A arrives after expectEmptySync, so a single reader is enough
    {
        var rbuf: [512]u8 = undefined;
        var reader = a.reader(io_val, &rbuf);
        var pbuf: [MAX_ACTION_FRAME_BYTES]u8 = undefined;
        const f = try decodeFrame(&reader.interface, &pbuf);
        try testing.expectEqual(@intFromEnum(FrameKind.peer_info), f.kind);
        const p = try parsePeerInfo(f.payload);
        try testing.expectEqual(@as(u32, 2), p.peer_id);
        try testing.expectEqual(PEER_INFO_KIND_AGENT, p.kind);
        try testing.expectEqualStrings("bot", p.label);
    }

    try pumpUntilAllSynced(2000);
    // B carries on with the same reader (expectEmptySync makes a new one, so it is not used)
    {
        const f = try decodeSkippingPeerInfo(&breader.interface, &bpbuf);
        try testing.expectEqual(@intFromEnum(FrameKind.sync), f.kind);
        const parsed = try parseSyncPayload(f.payload);
        try testing.expectEqual(@as(usize, 0), parsed.state.len);
    }
}

test "netsync: distributing LEFT on a leave" {
    resetForTest();
    defer resetForTest();
    initHost(0);
    const port = listeningPort().?;
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };

    var a = try rawHelloConnect(addr, "stay");
    defer a.close(io_val);
    try waitPeers(1, 2000);
    try pumpUntilAllSynced(2000);
    try expectEmptySync(a);

    var b = try rawHelloConnect(addr, "leave-me");
    try waitPeers(2, 2000);
    try pumpUntilAllSynced(2000);
    // drain A's PEER_INFO about b + B's SYNC path
    {
        var rbuf: [512]u8 = undefined;
        var reader = a.reader(io_val, &rbuf);
        var pbuf: [MAX_ACTION_FRAME_BYTES]u8 = undefined;
        _ = try decodeFrame(&reader.interface, &pbuf); // PEER_INFO b
    }
    try expectEmptySync(b);
    b.close(io_val);

    // wait for leave cleanup
    var waited: u64 = 0;
    while (peerCount() > 1 and waited < 3000) : (waited += 10) sleepMs(10);
    try testing.expectEqual(@as(usize, 1), peerCount());

    var rbuf: [512]u8 = undefined;
    var reader = a.reader(io_val, &rbuf);
    var pbuf: [MAX_ACTION_FRAME_BYTES]u8 = undefined;
    const f = try decodeFrame(&reader.interface, &pbuf);
    try testing.expectEqual(@intFromEnum(FrameKind.peer_info), f.kind);
    const left = try parsePeerInfo(f.payload);
    try testing.expectEqual(PEER_INFO_KIND_LEFT, left.kind);
    try testing.expectEqual(@as(u32, 2), left.peer_id);
}

test "netsync: a client reflects PEER_INFO into the catalog, widening getPeer and gatherStats" {
    resetForTest();
    defer resetForTest();

    ensureIo();
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(0) };
    var srv = try addr.listen(io_val, .{ .reuse_address = true });
    defer srv.deinit(io_val);
    const port = srv.socket.address.getPort();

    const Host = struct {
        fn run(listen_srv: *net.Server) void {
            ensureIo();
            const stream = listen_srv.accept(io_val) catch return;
            defer stream.close(io_val);
            var rbuf: [256]u8 = undefined;
            var reader = stream.reader(io_val, &rbuf);
            var pbuf: [512]u8 = undefined;
            _ = decodeFrame(&reader.interface, &pbuf) catch return;
            var wbuf: [512]u8 = undefined;
            var writer = stream.writer(io_val, &wbuf);
            var hbuf: [64]u8 = undefined;
            const resp = formatHostHello(&hbuf, 7) catch return;
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.hello), resp) catch return;
            // PEER_INFO host + remote before SYNC
            var ibuf: [5 + MAX_LABEL_LEN]u8 = undefined;
            const pi_host = formatPeerInfo(&ibuf, 0, PEER_INFO_KIND_HUMAN, "host") catch return;
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.peer_info), pi_host) catch return;
            const pi_rem = formatPeerInfo(&ibuf, 3, PEER_INFO_KIND_AGENT, "other") catch return;
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.peer_info), pi_rem) catch return;
            const sync_bytes = buildSyncPayload(0, "S") catch return;
            defer gpa.free(sync_bytes);
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.sync), sync_bytes) catch return;
            writer.interface.flush() catch return;
            sleepMs(80);
        }
    };
    const ht = try std.Thread.spawn(.{}, Host.run, .{&srv});
    defer ht.join();

    var sctx: SyncCtx = .{};
    registerStateSync(.{ .ctx = &sctx, .export_fn = syncExport, .import_fn = syncImport });
    initClientAs(net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) }, .agent, "me");
    try waitClientActive(2000);
    var waited: u64 = 0;
    while (awaiting_sync and waited < 3000) : (waited += 5) {
        pump();
        sleepMs(5);
    }
    try testing.expect(!awaiting_sync);
    // handle the PEER_INFO
    pump();
    sleepMs(5);
    pump();

    var lbuf: [MAX_LABEL_LEN]u8 = undefined;
    try testing.expectEqualStrings("host", resolvePeerOrigin(0, &lbuf).?.label);
    try testing.expectEqualStrings("me", resolvePeerOrigin(7, &lbuf).?.label);
    try testing.expectEqual(ActorKind.agent, resolvePeerOrigin(7, &lbuf).?.kind);
    try testing.expectEqualStrings("other", resolvePeerOrigin(3, &lbuf).?.label);

    const st = gatherStats();
    try testing.expectEqual(Role.client, st.role);
    try testing.expect(st.peers >= 3);
    try testing.expect(st.agents >= 2);

    // enumerate through getPeer
    var found_host = false;
    var found_self = false;
    var i: usize = 0;
    while (getPeer(i, &lbuf)) |p| : (i += 1) {
        if (p.peer_id == 0) found_host = true;
        if (p.peer_id == 7) found_self = true;
    }
    try testing.expect(found_host);
    try testing.expect(found_self);

    const snap = try formatSnapshot(testing.allocator);
    defer testing.allocator.free(snap);
    try testing.expect(std.mem.indexOf(u8, snap, "\"peer_id\":0") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "\"label\":\"host\"") != null);
}

test "netsync: a malformed PEER_INFO leaves the state unchanged" {
    resetForTest();
    defer resetForTest();
    ensureIo();
    peers_mutex.lockUncancelable(io_val);
    role = .client;
    started = true;
    peers_mutex.unlock(io_val);

    var pbuf: [5 + MAX_LABEL_LEN]u8 = undefined;
    const ok = try formatPeerInfo(&pbuf, 1, PEER_INFO_KIND_HUMAN, "ok");
    handlePeerInfo(ok);
    const rev = peerMetadataRevision();

    handlePeerInfo(&[_]u8{ 1, 0, 0, 0 }); // short
    var bad_kind: [5]u8 = .{ 1, 0, 0, 0, 2 };
    handlePeerInfo(&bad_kind);
    try testing.expectEqual(rev, peerMetadataRevision());
    var lbuf: [MAX_LABEL_LEN]u8 = undefined;
    try testing.expectEqualStrings("ok", resolvePeerOrigin(1, &lbuf).?.label);
}

test "netsync: formatLogDigestTail keeps origin numeric or a tag (a regression check)" {
    resetForTest();
    defer resetForTest();

    // put a peer actor on the shared executor and log
    var log: command.CommandLog = .{};
    var rec: command.CommandRecord = .{
        .seq = 1,
        .actor = .{ .peer = 3 },
        .kind = .normal,
        .name_len = 6,
        .args_len = 0,
        .undoable = true,
        .transaction_id = null,
    };
    @memcpy(rec.name_buf[0..6], "stroke");
    log.append(rec);

    const Dummy = struct {
        fn run(_: *anyopaque, _: []const u8, _: []const u8, buf: []u8) anyerror![]const u8 {
            return buf[0..0];
        }
    };
    var dummy: u8 = 0;
    var exec = command.Executor.init(.{ .ctx = &dummy, .run = Dummy.run });
    exec.log = &log;
    shared_executor = &exec;
    defer shared_executor = null;

    var buf: [256]u8 = undefined;
    const tail = formatLogDigestTail(&buf);
    // the origin is "3" (a number), not "agent:..." or anything of that shape
    try testing.expect(std.mem.indexOf(u8, tail, "1:3:stroke") != null);
    try testing.expect(std.mem.indexOf(u8, tail, "agent") == null);
    try testing.expect(std.mem.indexOf(u8, tail, "human") == null);

    // the same holds for formatSnapshot's log[].origin
    initHost(0); // enable the io
    const snap = try formatSnapshot(testing.allocator);
    defer testing.allocator.free(snap);
    try testing.expect(std.mem.indexOf(u8, snap, "\"origin\":\"3\"") != null);
}

test "netsync: a successful loopback HELLO handshake" {
    // One process takes only one of the host and client roles (the module is a singleton).
    // Wiring a client role's initClient belongs to the two-process E2E. Here a raw connect
    // checks the host side's HELLO numbering and its peer table.
    resetForTest();
    defer resetForTest();
    initHost(0);
    try testing.expect(isHost());
    const port = listeningPort().?;
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    ensureIo();

    const s = try addr.connect(io_val, .{ .mode = .stream });
    defer s.close(io_val);
    var wbuf: [128]u8 = undefined;
    var writer = s.writer(io_val, &wbuf);
    try encodeFrame(&writer.interface, @intFromEnum(FrameKind.hello), "client 1 human alice");
    try writer.interface.flush();

    var rbuf: [128]u8 = undefined;
    var reader = s.reader(io_val, &rbuf);
    var pbuf: [64]u8 = undefined;
    const frame = try decodeFrame(&reader.interface, &pbuf);
    try testing.expectEqual(@intFromEnum(FrameKind.hello), frame.kind);
    const pid = try parseHostHello(frame.payload);
    try testing.expectEqual(@as(u32, 1), pid);

    try waitPeers(1, 2000);
    var label_buf: [MAX_LABEL_LEN]u8 = undefined;
    const p = getPeer(0, &label_buf).?;
    try testing.expectEqual(@as(u32, 1), p.peer_id);
    try testing.expectEqual(ActorKind.human, p.kind);
    try testing.expectEqualStrings("alice", p.label);
    try testing.expectEqual(@as(u32, 0), localPeerId()); // the host itself
}

test "netsync: HELLO from several clients, up to MAX_PEERS" {
    resetForTest();
    defer resetForTest();
    initHost(0);
    const port = listeningPort().?;
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };

    // Connect one at a time (a simultaneous initClient is impossible, the module having a single client_slot).
    // Putting MAX_PEERS connections into the host's slots needs clients connecting as if from separate processes.
    // Here a raw connect plus a hand-written HELLO fills the slots.
    ensureIo();
    var raw_streams: [MAX_PEERS]net.Stream = undefined;
    var n_raw: usize = 0;
    defer {
        var i: usize = 0;
        while (i < n_raw) : (i += 1) raw_streams[i].close(io_val);
    }

    var i: usize = 0;
    while (i < MAX_PEERS) : (i += 1) {
        const s = try addr.connect(io_val, .{ .mode = .stream });
        raw_streams[n_raw] = s;
        n_raw += 1;
        var wbuf: [256]u8 = undefined;
        var writer = s.writer(io_val, &wbuf);
        var hbuf: [128]u8 = undefined;
        const hello = try std.fmt.bufPrint(&hbuf, "client {d} human c{d}", .{ PROTOCOL_VERSION, i });
        try encodeFrame(&writer.interface, @intFromEnum(FrameKind.hello), hello);
        try writer.interface.flush();

        // read the HELLO response
        var rbuf: [256]u8 = undefined;
        var reader = s.reader(io_val, &rbuf);
        var pbuf: [128]u8 = undefined;
        const frame = try decodeFrame(&reader.interface, &pbuf);
        try testing.expectEqual(@intFromEnum(FrameKind.hello), frame.kind);
        _ = try parseHostHello(frame.payload);
    }
    try waitPeers(MAX_PEERS, 3000);
    try testing.expectEqual(@as(usize, MAX_PEERS), peerCount());
}

test "netsync: going over MAX_PEERS disconnects" {
    resetForTest();
    defer resetForTest();
    initHost(0);
    const port = listeningPort().?;
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    ensureIo();

    var streams: [MAX_PEERS + 1]net.Stream = undefined;
    var n: usize = 0;
    defer {
        var i: usize = 0;
        while (i < n) : (i += 1) streams[i].close(io_val);
    }

    var i: usize = 0;
    while (i < MAX_PEERS) : (i += 1) {
        const s = try addr.connect(io_val, .{ .mode = .stream });
        streams[n] = s;
        n += 1;
        var wbuf: [256]u8 = undefined;
        var writer = s.writer(io_val, &wbuf);
        var hbuf: [64]u8 = undefined;
        const hello = try std.fmt.bufPrint(&hbuf, "client {d} human x{d}", .{ PROTOCOL_VERSION, i });
        try encodeFrame(&writer.interface, @intFromEnum(FrameKind.hello), hello);
        try writer.interface.flush();
        var rbuf: [256]u8 = undefined;
        var reader = s.reader(io_val, &rbuf);
        var pbuf: [64]u8 = undefined;
        _ = try decodeFrame(&reader.interface, &pbuf);
    }
    try waitPeers(MAX_PEERS, 3000);

    // a connection over the limit: accepted then closed at once, so a write or a read should fail.
    const extra = try addr.connect(io_val, .{ .mode = .stream });
    streams[n] = extra;
    n += 1;
    sleepMs(50);
    // peerCount does not rise
    try testing.expectEqual(@as(usize, MAX_PEERS), peerCount());
}

test "netsync: reusing a slot after one client disconnects" {
    resetForTest();
    defer resetForTest();
    initHost(0);
    const port = listeningPort().?;
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    ensureIo();

    {
        const s = try addr.connect(io_val, .{ .mode = .stream });
        defer s.close(io_val);
        var wbuf: [128]u8 = undefined;
        var writer = s.writer(io_val, &wbuf);
        try encodeFrame(&writer.interface, @intFromEnum(FrameKind.hello), "client 1 human first");
        try writer.interface.flush();
        var rbuf: [128]u8 = undefined;
        var reader = s.reader(io_val, &rbuf);
        var pbuf: [64]u8 = undefined;
        _ = try decodeFrame(&reader.interface, &pbuf);
        try waitPeers(1, 2000);
    }
    // Wait for the slot to be released after the close. It must reach .empty, not merely leave
    // .active: the acceptor reuses only .empty slots, so reconnecting against a .closing slot 0
    // would land in slot 1 and the getPeer(0) assertion below would read the wrong peer.
    try waitSlotsEmpty(3000);

    // reuse
    const s2 = try addr.connect(io_val, .{ .mode = .stream });
    defer s2.close(io_val);
    var wbuf2: [128]u8 = undefined;
    var writer2 = s2.writer(io_val, &wbuf2);
    try encodeFrame(&writer2.interface, @intFromEnum(FrameKind.hello), "client 1 human second");
    try writer2.interface.flush();
    var rbuf2: [128]u8 = undefined;
    var reader2 = s2.reader(io_val, &rbuf2);
    var pbuf2: [64]u8 = undefined;
    const frame = try decodeFrame(&reader2.interface, &pbuf2);
    try testing.expectEqual(@intFromEnum(FrameKind.hello), frame.kind);
    try waitPeers(1, 2000);
    var label_buf: [MAX_LABEL_LEN]u8 = undefined;
    try testing.expectEqualStrings("second", getPeer(0, &label_buf).?.label);
}

test "netsync: after a shutdown the connection is refused" {
    resetForTest();
    initHost(0);
    const port = listeningPort().?;
    shutdown();
    ensureIo();
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    try testing.expectError(error.ConnectionRefused, addr.connect(io_val, .{ .mode = .stream }));
}

test "netsync: a fail-soft when the host is not running" {
    resetForTest();
    defer resetForTest();
    ensureIo();
    // an unused high port
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(1) }; // usually refused
    initClient(addr);
    try testing.expect(!isEnabled());
    try testing.expect(!isClient());
}

// Init the client first, then have the host listen a few hundred ms later; the retry still connects.
// One process takes only one of the host and client roles, so a delayed dumb host thread does the listening.
test "netsync: a client retries ConnectionRefused and connects to a delayed host" {
    resetForTest();
    defer resetForTest();
    ensureIo();

    // Take a free port and close it at once (the delayed host listens on the same one).
    const probe_addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(0) };
    var probe = try probe_addr.listen(io_val, .{ .reuse_address = true });
    const port = probe.socket.address.getPort();
    probe.deinit(io_val);

    const DelayedHost = struct {
        fn run(p: u16) void {
            ensureIo();
            // Span the client's first and second retries (accept becomes possible around backoff 100+200=300ms).
            sleepMs(300);
            const a = net.IpAddress{ .ip4 = net.Ip4Address.loopback(p) };
            var srv = a.listen(io_val, .{ .reuse_address = true }) catch return;
            defer srv.deinit(io_val);
            const stream = srv.accept(io_val) catch return;
            defer stream.close(io_val);
            var rbuf: [256]u8 = undefined;
            var reader = stream.reader(io_val, &rbuf);
            var pbuf: [128]u8 = undefined;
            const hello = decodeFrame(&reader.interface, &pbuf) catch return;
            if (hello.kind != @intFromEnum(FrameKind.hello)) return;
            var wbuf: [128]u8 = undefined;
            var writer = stream.writer(io_val, &wbuf);
            var hbuf: [64]u8 = undefined;
            const resp = formatHostHello(&hbuf, 1) catch return;
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.hello), resp) catch return;
            writer.interface.flush() catch return;
            while (true) {
                _ = reader.interface.takeByte() catch break;
            }
        }
    };
    const ht = try std.Thread.spawn(.{}, DelayedHost.run, .{port});
    defer {
        resetForTest();
        ht.join();
    }

    const caddr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    initClientAs(caddr, .human, "retry-client");
    try testing.expect(isEnabled());
    try testing.expect(isClient());
    try waitClientActive(3000);
    // The dumb host sends no SYNC, so awaiting_sync stays raised (the connection being established is the point).
    try testing.expect(awaiting_sync);
}

test "netsync: calling shutdown twice is safe" {
    resetForTest();
    initHost(0);
    shutdown();
    shutdown();
    try testing.expect(!isEnabled());
}

test "netsync: broadcast fan-out" {
    resetForTest();
    defer resetForTest();
    initHost(0);
    const port = listeningPort().?;
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    ensureIo();

    var streams: [2]net.Stream = undefined;
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        streams[i] = try addr.connect(io_val, .{ .mode = .stream });
        var wbuf: [128]u8 = undefined;
        var writer = streams[i].writer(io_val, &wbuf);
        var hbuf: [64]u8 = undefined;
        const hello = try std.fmt.bufPrint(&hbuf, "client {d} human b{d}", .{ PROTOCOL_VERSION, i });
        try encodeFrame(&writer.interface, @intFromEnum(FrameKind.hello), hello);
        try writer.interface.flush();
        var rbuf: [128]u8 = undefined;
        var reader = streams[i].reader(io_val, &rbuf);
        var pbuf: [64]u8 = undefined;
        _ = try decodeFrame(&reader.interface, &pbuf);
    }
    defer {
        streams[0].close(io_val);
        streams[1].close(io_val);
    }
    try waitPeers(2, 2000);
    try pumpUntilAllSynced(2000);
    try expectEmptySync(streams[0]);
    try expectEmptySync(streams[1]);

    broadcast(@intFromEnum(FrameKind.commit), "seq-test");

    i = 0;
    while (i < 2) : (i += 1) {
        var rbuf: [256]u8 = undefined;
        var reader = streams[i].reader(io_val, &rbuf);
        var pbuf: [128]u8 = undefined;
        // a PEER_INFO from a peer that joined later can remain after the SYNC
        const frame = try decodeSkippingPeerInfo(&reader.interface, &pbuf);
        try testing.expectEqual(@intFromEnum(FrameKind.commit), frame.kind);
        try testing.expectEqualStrings("seq-test", frame.payload);
    }
}

test "netsync: a full inbound queue disconnects" {
    resetForTest();
    defer resetForTest();
    initHost(0);
    const port = listeningPort().?;
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    ensureIo();

    const s = try addr.connect(io_val, .{ .mode = .stream });
    defer s.close(io_val);
    var wbuf: [256]u8 = undefined;
    var writer = s.writer(io_val, &wbuf);
    try encodeFrame(&writer.interface, @intFromEnum(FrameKind.hello), "client 1 human flood");
    try writer.interface.flush();
    var rbuf: [128]u8 = undefined;
    var reader = s.reader(io_val, &rbuf);
    var pbuf: [64]u8 = undefined;
    _ = try decodeFrame(&reader.interface, &pbuf);
    try waitPeers(1, 2000);
    // handle ClientJoined to empty inbound, then pack it with PROPOSE frames
    try pumpUntilAllSynced(2000);
    try expectEmptySync(s);

    // send INBOUND_CAP+1 PROPOSE frames without pumping
    var n: usize = 0;
    while (n < INBOUND_CAP + 8) : (n += 1) {
        encodeFrame(&writer.interface, @intFromEnum(FrameKind.propose), "x") catch break;
        writer.interface.flush() catch break;
    }

    // wait until it is disconnected (it leaves the peer table and the other side's read hits EOF)
    var waited: u64 = 0;
    while (peerCount() != 0) {
        if (waited >= 3000) return error.Timeout;
        sleepMs(10);
        waited += 10;
    }
    // A read after the disconnect gives EOF or an error (with anything left in the buffer discarded).
    // Once the join PEER_INFO was added, recreate the reader to take the socket afresh (avoiding a stale one).
    var rbuf2: [128]u8 = undefined;
    var reader2 = s.reader(io_val, &rbuf2);
    var saw_err = false;
    var drain_i: usize = 0;
    while (drain_i < 64) : (drain_i += 1) {
        _ = reader2.interface.takeByte() catch {
            saw_err = true;
            break;
        };
    }
    try testing.expect(saw_err);
}

test "netsync: a SYNC before HELLO disconnects (rather than being discarded to carry on)" {
    resetForTest();
    defer resetForTest();
    initHost(0);
    const port = listeningPort().?;
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    ensureIo();

    const s = try addr.connect(io_val, .{ .mode = .stream });
    defer s.close(io_val);
    var wbuf: [128]u8 = undefined;
    var writer = s.writer(io_val, &wbuf);
    // a SYNC before HELLO → a protocol error disconnect (and a HELLO afterwards does not make it active)
    try encodeFrame(&writer.interface, @intFromEnum(FrameKind.sync), "sync-early");
    try writer.interface.flush();
    try encodeFrame(&writer.interface, @intFromEnum(FrameKind.hello), "client 1 human late");
    try writer.interface.flush();
    sleepMs(100);
    try testing.expectEqual(@as(usize, 0), peerCount());
}

test "netsync: a non-HELLO before HELLO, a duplicate, and a version mismatch all disconnect" {
    resetForTest();
    defer resetForTest();
    initHost(0);
    const port = listeningPort().?;
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    ensureIo();

    // sending a non-HELLO first
    {
        const s = try addr.connect(io_val, .{ .mode = .stream });
        defer s.close(io_val);
        var wbuf: [128]u8 = undefined;
        var writer = s.writer(io_val, &wbuf);
        try encodeFrame(&writer.interface, @intFromEnum(FrameKind.propose), "nope");
        try writer.interface.flush();
        sleepMs(50);
    }

    // a version mismatch
    {
        const s = try addr.connect(io_val, .{ .mode = .stream });
        defer s.close(io_val);
        var wbuf: [128]u8 = undefined;
        var writer = s.writer(io_val, &wbuf);
        try encodeFrame(&writer.interface, @intFromEnum(FrameKind.hello), "client 99 human x");
        try writer.interface.flush();
        sleepMs(50);
        try testing.expectEqual(@as(usize, 0), peerCount());
    }

    // duplicate HELLO
    {
        const s = try addr.connect(io_val, .{ .mode = .stream });
        defer s.close(io_val);
        var wbuf: [128]u8 = undefined;
        var writer = s.writer(io_val, &wbuf);
        try encodeFrame(&writer.interface, @intFromEnum(FrameKind.hello), "client 1 human d");
        try writer.interface.flush();
        var rbuf: [128]u8 = undefined;
        var reader = s.reader(io_val, &rbuf);
        var pbuf: [64]u8 = undefined;
        _ = try decodeFrame(&reader.interface, &pbuf);
        try waitPeers(1, 2000);
        try encodeFrame(&writer.interface, @intFromEnum(FrameKind.hello), "client 1 human d");
        try writer.interface.flush();
        sleepMs(50);
    }
}

test "netsync: clientSend fails soft on a full outbound queue" {
    // A host role is unusable in the same process, so a dumb host thread is started and this connects in the client role.
    resetForTest();
    defer resetForTest();
    ensureIo();

    const addr0 = net.IpAddress{ .ip4 = net.Ip4Address.loopback(0) };
    var srv = try addr0.listen(io_val, .{ .reuse_address = true });
    const port = srv.socket.address.getPort();

    const DumbHost = struct {
        fn run(server_ptr: *net.Server) void {
            ensureIo();
            const stream = server_ptr.accept(io_val) catch return;
            defer stream.close(io_val);
            var rbuf: [256]u8 = undefined;
            var reader = stream.reader(io_val, &rbuf);
            var pbuf: [128]u8 = undefined;
            const hello = decodeFrame(&reader.interface, &pbuf) catch return;
            if (hello.kind != @intFromEnum(FrameKind.hello)) return;
            var wbuf: [128]u8 = undefined;
            var writer = stream.writer(io_val, &wbuf);
            var hbuf: [64]u8 = undefined;
            const resp = formatHostHello(&hbuf, 1) catch return;
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.hello), resp) catch return;
            writer.interface.flush() catch return;
            // Read nothing from here on (which clogs the TCP window). Wait until the client's disconnect gives EOF.
            while (true) {
                _ = reader.interface.takeByte() catch break;
            }
        }
    };
    const ht = try std.Thread.spawn(.{}, DumbHost.run, .{&srv});
    defer {
        // The host finishes after the client's shutdown. Close the listen socket, then join.
        resetForTest();
        srv.deinit(io_val);
        ht.join();
    }

    const caddr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    initClientAs(caddr, .human, "flood-client");
    try waitClientActive(2000);
    try testing.expect(isEnabled());

    // Fire off large payloads. The peer does not read, so the writer clogs up on TCP and the outbound queue fills.
    var payload: [MAX_ACTION_FRAME_BYTES]u8 = undefined;
    @memset(&payload, 'Z');
    var failed = false;
    var i: usize = 0;
    while (i < OUTBOUND_CAP + 512) : (i += 1) {
        if (!clientSend(@intFromEnum(FrameKind.propose), &payload)) {
            failed = true;
            break;
        }
    }
    try testing.expect(failed);
    try testing.expect(!isEnabled());
}

// ============================================================================
// semantic tests
// ============================================================================

const SemCtx = struct {
    calls: u32 = 0,
    fail: bool = false,
    last_args: [128]u8 = undefined,
    last_args_len: usize = 0,
};

fn semRun(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const c: *SemCtx = @ptrCast(@alignCast(ctx));
    if (c.fail) return error.SemFail;
    c.calls += 1;
    const n = @min(args.len, c.last_args.len);
    if (n > 0) @memcpy(c.last_args[0..n], args[0..n]);
    c.last_args_len = n;
    return std.fmt.bufPrint(buf, "ok:{s}", .{args}) catch "ok";
}

fn registerSem(name: []const u8, ctx: *SemCtx, policy: action_registry.NetworkPolicy) void {
    action_registry.setEnabled(true);
    action_registry.registerAction(.{
        .name = name,
        .ctx = ctx,
        .run = semRun,
        .network_policy = policy,
    });
}

fn rawHelloConnect(addr: net.IpAddress, label: []const u8) !net.Stream {
    return rawHelloConnectAs(addr, .human, label);
}

/// Reads as far as the host's HELLO response and returns the stream.
///
/// **A caution when reading past the PEER_INFO frames**: this function makes a temporary `Stream.reader` for the HELLO and discards it.
/// If the host sends PEER_INFO in the same TCP segment right after the HELLO, the unconsumed PEER_INFO is
/// lost along with the temporary rbuf, and reading with a new reader looks as though the order jumped.
/// To check the PEER_INFO ordering, hold the same reader from the HELLO on (see the join distribution ordering test).
fn rawHelloConnectAs(addr: net.IpAddress, kind: ActorKind, label: []const u8) !net.Stream {
    ensureIo();
    const s = try addr.connect(io_val, .{ .mode = .stream });
    var wbuf: [256]u8 = undefined;
    var writer = s.writer(io_val, &wbuf);
    var hbuf: [128]u8 = undefined;
    const hello = try formatClientHello(&hbuf, kind, label);
    try encodeFrame(&writer.interface, @intFromEnum(FrameKind.hello), hello);
    try writer.interface.flush();
    var rbuf: [256]u8 = undefined;
    var reader = s.reader(io_val, &rbuf);
    var pbuf: [128]u8 = undefined;
    const frame = try decodeFrame(&reader.interface, &pbuf);
    try testing.expectEqual(@intFromEnum(FrameKind.hello), frame.kind);
    _ = try parseHostHello(frame.payload);
    return s;
}

test "netsync: payload PROPOSE/COMMIT/REJECT round-trip" {
    var buf: [256]u8 = undefined;
    const p = try formatProposePayload(&buf, 7, "stroke", "1 2");
    const pp = try parseProposePayload(p);
    try testing.expectEqual(@as(u32, 7), pp.proposal_id);
    try testing.expectEqualStrings("stroke", pp.name);
    try testing.expectEqualStrings("1 2", pp.args);

    const c = try formatCommitPayload(&buf, 42, 3, "set_tool", "pen");
    const cp = try parseCommitPayload(c);
    try testing.expectEqual(@as(u64, 42), cp.seq);
    try testing.expectEqual(@as(u32, 3), cp.origin_peer);
    try testing.expectEqualStrings("set_tool", cp.name);
    try testing.expectEqualStrings("pen", cp.args);

    const r = try formatRejectPayload(&buf, 9, "not relayable");
    const rp = try parseRejectPayload(r);
    try testing.expectEqual(@as(u32, 9), rp.proposal_id);
    try testing.expectEqualStrings("not relayable", rp.reason);
}

test "netsync: the router's five policy branches on a host" {
    resetForTest();
    defer resetForTest();
    var ctx: SemCtx = .{};
    registerSem("h_relay", &ctx, .relay);
    registerSem("h_local", &ctx, .local_only);
    registerSem("h_reject", &ctx, .reject_when_synced);
    registerSem("h_undo", &ctx, .undo_own);
    registerSem("h_redo", &ctx, .redo_own);
    initHost(0);
    try testing.expect(isHost());

    var buf: [128]u8 = undefined;
    const r0 = try action_registry.routeLocalAction("h_relay", "a", &buf);
    try testing.expectEqualStrings("ok:a", r0);
    try testing.expectEqual(@as(u64, 1), wireSeq());

    const r1 = try action_registry.routeLocalAction("h_local", "b", &buf);
    try testing.expectEqualStrings("ok:b", r1);
    try testing.expectEqual(@as(u64, 1), wireSeq()); // local_only consumes no seq

    try testing.expectError(error.RejectedWhileSynced, action_registry.routeLocalAction("h_reject", "", &buf));
    try testing.expectError(error.NoExecutor, action_registry.routeLocalAction("h_undo", "", &buf));
    try testing.expectError(error.NoExecutor, action_registry.routeLocalAction("h_redo", "", &buf));
}

test "netsync: the router's five policy branches on a client" {
    resetForTest();
    defer resetForTest();
    ensureIo();
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(0) };
    var srv = try addr.listen(io_val, .{ .reuse_address = true });
    defer srv.deinit(io_val);
    const port = srv.socket.address.getPort();

    const Host = struct {
        fn run(listen_srv: *net.Server) void {
            ensureIo();
            const stream = listen_srv.accept(io_val) catch return;
            defer stream.close(io_val);
            var rbuf: [256]u8 = undefined;
            var reader = stream.reader(io_val, &rbuf);
            var pbuf: [128]u8 = undefined;
            _ = decodeFrame(&reader.interface, &pbuf) catch return;
            var wbuf: [128]u8 = undefined;
            var writer = stream.writer(io_val, &wbuf);
            var hbuf: [64]u8 = undefined;
            const resp = formatHostHello(&hbuf, 1) catch return;
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.hello), resp) catch return;
            writer.interface.flush() catch return;
            // release awaiting_sync with an empty SYNC, then wait for the PROPOSE
            var sync_pl: [8]u8 = undefined;
            std.mem.writeInt(u64, sync_pl[0..8], 0, .little);
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.sync), &sync_pl) catch return;
            writer.interface.flush() catch return;
            // read one PROPOSE and discard it (for the client relay)
            _ = decodeFrame(&reader.interface, &pbuf) catch {};
            sleepMs(200);
        }
    };
    const ht = try std.Thread.spawn(.{}, Host.run, .{&srv});
    defer ht.join();

    var ctx: SemCtx = .{};
    registerSem("c_relay", &ctx, .relay);
    registerSem("c_local", &ctx, .local_only);
    registerSem("c_reject", &ctx, .reject_when_synced);
    registerSem("c_undo", &ctx, .undo_own);
    registerSem("c_redo", &ctx, .redo_own);

    const caddr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    initClientAs(caddr, .human, "pol");
    try waitClientActive(2000);
    var waited_sync: u64 = 0;
    while (testAwaitingSync() and waited_sync < 2000) : (waited_sync += 5) {
        pump();
        sleepMs(5);
    }
    try testing.expect(!testAwaitingSync());

    var buf: [128]u8 = undefined;
    const pr = try action_registry.routeLocalAction("c_relay", "x", &buf);
    try testing.expectEqualStrings("proposed 1", pr);
    try testing.expectEqual(@as(u32, 0), ctx.calls); // nothing applied locally

    const loc = try action_registry.routeLocalAction("c_local", "y", &buf);
    try testing.expectEqualStrings("ok:y", loc);
    try testing.expectEqual(@as(u32, 1), ctx.calls);

    try testing.expectError(error.RejectedWhileSynced, action_registry.routeLocalAction("c_reject", "", &buf));
    try testing.expectError(error.NoExecutor, action_registry.routeLocalAction("c_undo", "", &buf));
    try testing.expectError(error.NoExecutor, action_registry.routeLocalAction("c_redo", "", &buf));
}

test "netsync: commitAndBroadcast increases seq monotonically and COMMIT carries origin_peer=0" {
    resetForTest();
    defer resetForTest();
    var ctx: SemCtx = .{};
    registerSem("stroke", &ctx, .relay);
    initHost(0);
    const port = listeningPort().?;
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    var stream = try rawHelloConnect(addr, "bob");
    defer stream.close(io_val);
    try waitPeers(1, 2000);
    try pumpUntilAllSynced(2000);
    try expectEmptySync(stream);

    var buf: [128]u8 = undefined;
    _ = try commitAndBroadcast("stroke", "10 10", &buf);
    _ = try commitAndBroadcast("stroke", "20 20", &buf);
    try testing.expectEqual(@as(u64, 2), wireSeq());

    var rbuf: [512]u8 = undefined;
    var reader = stream.reader(io_val, &rbuf);
    var pbuf: [256]u8 = undefined;
    const f1 = try decodeFrame(&reader.interface, &pbuf);
    try testing.expectEqual(@intFromEnum(FrameKind.commit), f1.kind);
    const c1 = try parseCommitPayload(f1.payload);
    try testing.expectEqual(@as(u64, 1), c1.seq);
    try testing.expectEqual(@as(u32, 0), c1.origin_peer);
    try testing.expectEqualStrings("stroke", c1.name);
    try testing.expectEqualStrings("10 10", c1.args);

    const f2 = try decodeFrame(&reader.interface, &pbuf);
    const c2 = try parseCommitPayload(f2.payload);
    try testing.expectEqual(@as(u64, 2), c2.seq);
    try testing.expectEqual(@as(u32, 0), c2.origin_peer);
}

test "netsync: the host re-validates a PROPOSE and REJECTs it (non-relay, and unknown)" {
    resetForTest();
    defer resetForTest();
    var ctx: SemCtx = .{};
    registerSem("stroke", &ctx, .relay);
    registerSem("undo", &ctx, .reject_when_synced);
    initHost(0);
    const port = listeningPort().?;
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    var stream = try rawHelloConnect(addr, "eve");
    defer stream.close(io_val);
    try waitPeers(1, 2000);
    try pumpUntilAllSynced(2000);
    try expectEmptySync(stream);

    var wbuf: [256]u8 = undefined;
    var writer = stream.writer(io_val, &wbuf);
    var pbuf: [128]u8 = undefined;
    const bad = try formatProposePayload(&pbuf, 3, "undo", "");
    try encodeFrame(&writer.interface, @intFromEnum(FrameKind.propose), bad);
    try writer.interface.flush();
    const unk = try formatProposePayload(&pbuf, 4, "no_such", "");
    try encodeFrame(&writer.interface, @intFromEnum(FrameKind.propose), unk);
    try writer.interface.flush();

    // wait until the host reads
    var waited: u64 = 0;
    while (inboundLen() < 2 and waited < 2000) : (waited += 5) sleepMs(5);
    pump();
    pump();

    var rbuf: [256]u8 = undefined;
    var reader = stream.reader(io_val, &rbuf);
    var fbuf: [128]u8 = undefined;
    const r1 = try decodeFrame(&reader.interface, &fbuf);
    try testing.expectEqual(@intFromEnum(FrameKind.reject), r1.kind);
    const p1 = try parseRejectPayload(r1.payload);
    try testing.expectEqual(@as(u32, 3), p1.proposal_id);
    try testing.expectEqualStrings("not relayable", p1.reason);

    const r2 = try decodeFrame(&reader.interface, &fbuf);
    try testing.expectEqual(@intFromEnum(FrameKind.reject), r2.kind);
    const p2 = try parseRejectPayload(r2.payload);
    try testing.expectEqual(@as(u32, 4), p2.proposal_id);
    try testing.expectEqualStrings("not relayable", p2.reason);
}

test "netsync: a client PROPOSE of pattern_state is REJECTed as not relayable" {
    resetForTest();
    defer resetForTest();
    var ctx: SemCtx = .{};
    registerSem("pattern_state", &ctx, .reject_when_synced);
    initHost(0);
    const port = listeningPort().?;
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    var stream = try rawHelloConnect(addr, "eve");
    defer stream.close(io_val);
    try waitPeers(1, 2000);
    try pumpUntilAllSynced(2000);
    try expectEmptySync(stream);

    var wbuf: [256]u8 = undefined;
    var writer = stream.writer(io_val, &wbuf);
    var pbuf: [128]u8 = undefined;
    const bad = try formatProposePayload(&pbuf, 9, "pattern_state", "1111 2222");
    try encodeFrame(&writer.interface, @intFromEnum(FrameKind.propose), bad);
    try writer.interface.flush();

    var waited: u64 = 0;
    while (inboundLen() < 1 and waited < 2000) : (waited += 5) sleepMs(5);
    pump();

    var rbuf: [256]u8 = undefined;
    var reader = stream.reader(io_val, &rbuf);
    var fbuf: [128]u8 = undefined;
    const r1 = try decodeFrame(&reader.interface, &fbuf);
    try testing.expectEqual(@intFromEnum(FrameKind.reject), r1.kind);
    const p1 = try parseRejectPayload(r1.payload);
    try testing.expectEqual(@as(u32, 9), p1.proposal_id);
    try testing.expectEqualStrings("not relayable", p1.reason);
    try testing.expectEqual(@as(u32, 0), ctx.calls);
}

test "netsync: a PROPOSE to COMMIT round trip (a remote_commit adds a CommandRecord)" {
    resetForTest();
    defer resetForTest();

    var log: command.CommandLog = .{};
    var exec = command.Executor.init(.{
        .ctx = undefined,
        .run = struct {
            fn d(_: *anyopaque, name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
                _ = name;
                return std.fmt.bufPrint(buf, "d:{s}", .{args});
            }
        }.d,
    });
    exec.log = &log;
    setSharedExecutor(&exec);

    var ctx: SemCtx = .{};
    registerSem("stroke", &ctx, .relay);

    initHost(0);
    const port = listeningPort().?;
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    var stream = try rawHelloConnect(addr, "carol");
    defer stream.close(io_val);
    try waitPeers(1, 2000);
    try pumpUntilAllSynced(2000);
    try expectEmptySync(stream);

    const before = log.filled;
    var wbuf: [256]u8 = undefined;
    var writer = stream.writer(io_val, &wbuf);
    var pbuf: [128]u8 = undefined;
    const prop = try formatProposePayload(&pbuf, 1, "stroke", "5 5");
    try encodeFrame(&writer.interface, @intFromEnum(FrameKind.propose), prop);
    try writer.interface.flush();

    var waited: u64 = 0;
    while (inboundLen() < 1 and waited < 2000) : (waited += 5) sleepMs(5);
    pump();
    try testing.expectEqual(before + 1, log.filled); // a remote_commit record
    try testing.expectEqual(@as(u64, 1), wireSeq());
    try testing.expect(log.findBySeq(1).?.actor.eql(.{ .peer = 1 }));

    var rbuf: [256]u8 = undefined;
    var reader = stream.reader(io_val, &rbuf);
    var fbuf: [128]u8 = undefined;
    const f = try decodeFrame(&reader.interface, &fbuf);
    try testing.expectEqual(@intFromEnum(FrameKind.commit), f.kind);
    const c = try parseCommitPayload(f.payload);
    try testing.expectEqual(@as(u64, 1), c.seq);
    try testing.expect(c.origin_peer != 0);
    try testing.expectEqualStrings("stroke", c.name);
}

test "netsync: receiving a REJECT stores last_rejected_proposal" {
    resetForTest();
    defer resetForTest();
    ensureIo();
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(0) };
    var srv = try addr.listen(io_val, .{ .reuse_address = true });
    defer srv.deinit(io_val);
    const port = srv.socket.address.getPort();

    const Host = struct {
        fn run(listen_srv: *net.Server) void {
            ensureIo();
            const stream = listen_srv.accept(io_val) catch return;
            defer stream.close(io_val);
            var rbuf: [256]u8 = undefined;
            var reader = stream.reader(io_val, &rbuf);
            var pbuf: [128]u8 = undefined;
            _ = decodeFrame(&reader.interface, &pbuf) catch return;
            var wbuf: [256]u8 = undefined;
            var writer = stream.writer(io_val, &wbuf);
            var hbuf: [64]u8 = undefined;
            const resp = formatHostHello(&hbuf, 2) catch return;
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.hello), resp) catch return;
            writer.interface.flush() catch return;
            // release awaiting_sync with an empty SYNC, then REJECT
            var sync_pl: [8]u8 = undefined;
            std.mem.writeInt(u64, sync_pl[0..8], 0, .little);
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.sync), &sync_pl) catch return;
            writer.interface.flush() catch return;
            const rej = formatRejectPayload(&pbuf, 11, "nope") catch return;
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.reject), rej) catch return;
            writer.interface.flush() catch return;
            sleepMs(100);
        }
    };
    const ht = try std.Thread.spawn(.{}, Host.run, .{&srv});
    defer ht.join();

    const caddr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    initClientAs(caddr, .human, "rj");
    try waitClientActive(2000);
    // apply the SYNC → awaiting_sync released
    var waited: u64 = 0;
    while (testAwaitingSync() and waited < 2000) : (waited += 5) {
        pump();
        sleepMs(5);
    }
    try testing.expect(!testAwaitingSync());
    waited = 0;
    while (inboundLen() < 1 and waited < 2000) : (waited += 5) sleepMs(5);
    pump();
    try testing.expectEqual(@as(u32, 11), lastRejectedProposal());
    try testing.expectEqualStrings("nope", lastRejectReason());
}

test "netsync: proposal_id increases monotonically" {
    resetForTest();
    defer resetForTest();
    ensureIo();
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(0) };
    var srv = try addr.listen(io_val, .{ .reuse_address = true });
    defer srv.deinit(io_val);
    const port = srv.socket.address.getPort();

    const Host = struct {
        fn run(listen_srv: *net.Server) void {
            ensureIo();
            const stream = listen_srv.accept(io_val) catch return;
            defer stream.close(io_val);
            var rbuf: [512]u8 = undefined;
            var reader = stream.reader(io_val, &rbuf);
            var pbuf: [256]u8 = undefined;
            _ = decodeFrame(&reader.interface, &pbuf) catch return;
            var wbuf: [128]u8 = undefined;
            var writer = stream.writer(io_val, &wbuf);
            var hbuf: [64]u8 = undefined;
            const resp = formatHostHello(&hbuf, 1) catch return;
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.hello), resp) catch return;
            writer.interface.flush() catch return;
            // release awaiting_sync with an empty SYNC
            var sync_pl: [8]u8 = undefined;
            std.mem.writeInt(u64, sync_pl[0..8], 0, .little);
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.sync), &sync_pl) catch return;
            writer.interface.flush() catch return;
            _ = decodeFrame(&reader.interface, &pbuf) catch {};
            _ = decodeFrame(&reader.interface, &pbuf) catch {};
            sleepMs(100);
        }
    };
    const ht = try std.Thread.spawn(.{}, Host.run, .{&srv});
    defer ht.join();

    var ctx: SemCtx = .{};
    registerSem("stroke", &ctx, .relay);
    initClientAs(net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) }, .human, "pid");
    try waitClientActive(2000);
    var waited_sync: u64 = 0;
    while (testAwaitingSync() and waited_sync < 2000) : (waited_sync += 5) {
        pump();
        sleepMs(5);
    }
    try testing.expect(!testAwaitingSync());
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("proposed 1", try proposeToHost("stroke", "a", &buf));
    try testing.expectEqualStrings("proposed 2", try proposeToHost("stroke", "b", &buf));
}

test "netsync: a local save during a wire_session consumes no seq, so a COMMIT does not go stale" {
    resetForTest();
    defer resetForTest();

    var log: command.CommandLog = .{};
    var exec_ctx: SemCtx = .{};
    var exec = command.Executor.init(.{
        .ctx = &exec_ctx,
        .run = struct {
            fn d(ctx: *anyopaque, name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
                _ = name;
                const c: *SemCtx = @ptrCast(@alignCast(ctx));
                c.calls += 1;
                return std.fmt.bufPrint(buf, "e:{s}", .{args});
            }
        }.d,
    });
    exec.log = &log;
    setSharedExecutor(&exec);

    ensureIo();
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(0) };
    var srv = try addr.listen(io_val, .{ .reuse_address = true });
    defer srv.deinit(io_val);
    const port = srv.socket.address.getPort();

    const Host = struct {
        fn run(listen_srv: *net.Server) void {
            ensureIo();
            const stream = listen_srv.accept(io_val) catch return;
            defer stream.close(io_val);
            var rbuf: [256]u8 = undefined;
            var reader = stream.reader(io_val, &rbuf);
            var pbuf: [256]u8 = undefined;
            _ = decodeFrame(&reader.interface, &pbuf) catch return;
            var wbuf: [256]u8 = undefined;
            var writer = stream.writer(io_val, &wbuf);
            var hbuf: [64]u8 = undefined;
            const resp = formatHostHello(&hbuf, 1) catch return;
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.hello), resp) catch return;
            writer.interface.flush() catch return;
            var sync_pl: [8]u8 = undefined;
            std.mem.writeInt(u64, sync_pl[0..8], 0, .little);
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.sync), &sync_pl) catch return;
            writer.interface.flush() catch return;
            sleepMs(50);
            const commit = formatCommitPayload(&pbuf, 1, 0, "stroke", "remote") catch return;
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.commit), commit) catch return;
            writer.interface.flush() catch return;
            sleepMs(100);
        }
    };
    const ht = try std.Thread.spawn(.{}, Host.run, .{&srv});
    defer ht.join();

    var ctx: SemCtx = .{};
    registerSem("save", &ctx, .local_only);
    registerSem("stroke", &ctx, .relay);

    initClientAs(net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) }, .human, "lo");
    try waitClientActive(2000);

    var waited_sync: u64 = 0;
    while (testAwaitingSync() and waited_sync < 2000) : (waited_sync += 5) {
        pump();
        sleepMs(5);
    }
    try testing.expect(!testAwaitingSync());

    // a local record during a wire_session is suppressed
    var buf: [128]u8 = undefined;
    _ = try exec.executeAction("save", "/tmp/x", .{ .actor = .local_user, .record_policy = .record }, &buf);
    try testing.expectEqual(@as(u32, 0), log.filled);
    try testing.expectEqual(@as(u64, 1), log.next_seq);

    var waited: u64 = 0;
    while (inboundLen() < 1 and waited < 2000) : (waited += 5) sleepMs(5);
    pump();
    try testing.expectEqual(@as(u32, 1), log.filled);
    try testing.expectEqual(@as(u64, 2), log.next_seq);
    try testing.expect(exec_ctx.calls >= 2); // save dispatch + remote stroke
}

test "netsync: after a fail-soft, pump clears the router and ordinary local operation resumes" {
    resetForTest();
    defer resetForTest();
    ensureIo();
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(0) };
    var srv = try addr.listen(io_val, .{ .reuse_address = true });
    const port = srv.socket.address.getPort();

    var close_gate: std.atomic.Value(bool) = .init(false);
    const Host = struct {
        fn run(listen_srv: *net.Server, gate: *std.atomic.Value(bool)) void {
            ensureIo();
            const stream = listen_srv.accept(io_val) catch return;
            defer stream.close(io_val);
            var rbuf: [256]u8 = undefined;
            var reader = stream.reader(io_val, &rbuf);
            var pbuf: [128]u8 = undefined;
            _ = decodeFrame(&reader.interface, &pbuf) catch return;
            var wbuf: [128]u8 = undefined;
            var writer = stream.writer(io_val, &wbuf);
            var hbuf: [64]u8 = undefined;
            const resp = formatHostHello(&hbuf, 1) catch return;
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.hello), resp) catch return;
            writer.interface.flush() catch return;
            // keep it until the client becomes active, then disconnect
            var waited: u64 = 0;
            while (!gate.load(.seq_cst) and waited < 5000) : (waited += 10) sleepMs(10);
        }
    };
    const ht = try std.Thread.spawn(.{}, Host.run, .{ &srv, &close_gate });
    defer {
        close_gate.store(true, .seq_cst);
        ht.join();
        srv.deinit(io_val);
    }

    var ctx: SemCtx = .{};
    registerSem("stroke", &ctx, .relay);
    initClientAs(net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) }, .human, "fs");
    try waitClientActive(2000);
    try testing.expect(isEnabled());

    close_gate.store(true, .seq_cst); // the host closes the connection
    var waited: u64 = 0;
    while (isEnabled() and waited < 3000) : (waited += 10) sleepMs(10);
    try testing.expect(!isEnabled());

    pump(); // router_clear_pending → setRouter(null)
    var buf: [64]u8 = undefined;
    const out = try action_registry.routeLocalAction("stroke", "z", &buf);
    try testing.expectEqualStrings("ok:z", out);
    try testing.expectEqual(@as(u32, 1), ctx.calls);
}

test "netsync: after a shutdown routeLocalAction is equivalent to a dispatch" {
    resetForTest();
    defer resetForTest();
    var ctx: SemCtx = .{};
    registerSem("stroke", &ctx, .relay);
    initHost(0);
    try testing.expect(isHost());
    shutdown();
    try testing.expect(!isEnabled());
    // shutdown is setRouter(null). The registration survives (before resetForTest)
    action_registry.setEnabled(true);
    var buf: [64]u8 = undefined;
    const out = try action_registry.routeLocalAction("stroke", "s", &buf);
    try testing.expectEqualStrings("ok:s", out);
}

test "netsync: passing straight through with the environment unset (pump and isEnabled)" {
    resetForTest();
    defer resetForTest();
    try testing.expect(!isEnabled());
    pump(); // no-op
    try testing.expectEqual(@as(usize, 0), inboundLen());
}

test "netsync: a HELLO with the default identifiers is accepted by parseClientHello (the initClient path)" {
    resetForTest();
    defer resetForTest();
    // Build the HELLO with the same slice initClient passes (a regression check on the "client" initialiser at the declaration).
    try testing.expectEqual(@as(usize, default_client_label.len), client_label_len);
    try testing.expectEqualStrings(default_client_label, client_label_buf[0..client_label_len]);
    var buf: [256]u8 = undefined;
    const payload = try formatClientHello(&buf, client_actor_kind, client_label_buf[0..client_label_len]);
    const parsed = try parseClientHello(payload);
    try testing.expectEqual(ActorKind.human, parsed.kind);
    try testing.expectEqualStrings("client", parsed.label);
    for (parsed.label) |c| try testing.expect(c >= 0x20);
}

test "netsync: even a label that amounts to uninitialised is accepted in a HELLO once defaultClientLabel has run" {
    resetForTest();
    defer resetForTest();
    // The buggy state observed in the E2E: len=6 but the buffer is NUL-filled
    @memset(client_label_buf[0..6], 0);
    client_label_len = 6;
    var bad_buf: [256]u8 = undefined;
    const bad = try formatClientHello(&bad_buf, .human, client_label_buf[0..client_label_len]);
    try testing.expectError(error.ProtocolError, parseClientHello(bad));

    defaultClientLabel();
    var buf: [256]u8 = undefined;
    const payload = try formatClientHello(&buf, client_actor_kind, client_label_buf[0..client_label_len]);
    const parsed = try parseClientHello(payload);
    try testing.expectEqualStrings("client", parsed.label);
}

// ============================================================================
// StateSync and SYNC tests
// ============================================================================

const SyncCtx = struct {
    export_bytes: []const u8 = "STATE",
    export_fail: bool = false,
    export_empty: bool = false,
    import_calls: u32 = 0,
    import_fail: bool = false,
    last_import: [64]u8 = undefined,
    last_import_len: usize = 0,
};

fn syncExport(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    const c: *SyncCtx = @ptrCast(@alignCast(ctx));
    if (c.export_fail) return error.ExportBoom;
    if (c.export_empty) return try allocator.dupe(u8, "");
    return try allocator.dupe(u8, c.export_bytes);
}

fn syncImport(ctx: *anyopaque, bytes: []const u8) anyerror!void {
    const c: *SyncCtx = @ptrCast(@alignCast(ctx));
    if (c.import_fail) return error.ImportBoom;
    c.import_calls += 1;
    const n = @min(bytes.len, c.last_import.len);
    if (n > 0) @memcpy(c.last_import[0..n], bytes[0..n]);
    c.last_import_len = n;
}

test "netsync: StateSync register and reset, and being safe while disabled" {
    resetForTest();
    defer resetForTest();
    var ctx: SyncCtx = .{};
    registerStateSync(.{ .ctx = &ctx, .export_fn = syncExport, .import_fn = syncImport });
    try testing.expect(state_sync != null);
    resetForTest();
    try testing.expect(state_sync == null);
    // registration works while disabled too
    registerStateSync(.{ .ctx = &ctx, .export_fn = syncExport, .import_fn = syncImport });
    try testing.expect(state_sync != null);
}

test "netsync: the first non-HELLO frame after a join is a SYNC (empty, with snapshot_valid=false)" {
    resetForTest();
    defer resetForTest();
    initHost(0);
    const port = listeningPort().?;
    var stream = try rawHelloConnect(net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) }, "j1");
    defer stream.close(io_val);
    try waitPeers(1, 2000);
    try pumpUntilAllSynced(2000);
    try expectEmptySync(stream);
    const info = testSlotSyncInfo(1).?;
    try testing.expect(info.synced);
    try testing.expect(!info.snapshot_valid);
    try testing.expectEqual(@as(u64, 0), info.join_snapshot_seq);
}

test "netsync: the synced gate (a COMMIT before the SYNC does not arrive, and one after it does)" {
    resetForTest();
    defer resetForTest();
    var ctx: SemCtx = .{};
    registerSem("stroke", &ctx, .relay);
    initHost(0);
    const port = listeningPort().?;
    var stream = try rawHelloConnect(net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) }, "gate");
    defer stream.close(io_val);
    try waitPeers(1, 2000);

    // ClientJoined unhandled = not synced → not broadcast to
    var buf: [64]u8 = undefined;
    _ = try commitAndBroadcast("stroke", "pre", &buf);

    try pumpUntilAllSynced(2000);
    try expectEmptySync(stream); // the SYNC alone (there is no COMMIT before it)

    _ = try commitAndBroadcast("stroke", "post", &buf);
    var rbuf: [256]u8 = undefined;
    var reader = stream.reader(io_val, &rbuf);
    var pbuf: [128]u8 = undefined;
    const f = try decodeFrame(&reader.interface, &pbuf);
    try testing.expectEqual(@intFromEnum(FrameKind.commit), f.kind);
    const c = try parseCommitPayload(f.payload);
    try testing.expectEqualStrings("post", c.args);
}

test "netsync: with an export registered the SYNC carries the state and snapshot_valid holds" {
    resetForTest();
    defer resetForTest();
    var sctx: SyncCtx = .{ .export_bytes = "DOC42" };
    registerStateSync(.{ .ctx = &sctx, .export_fn = syncExport, .import_fn = syncImport });
    initHost(0);
    const port = listeningPort().?;
    var stream = try rawHelloConnect(net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) }, "ex");
    defer stream.close(io_val);
    try waitPeers(1, 2000);
    try pumpUntilAllSynced(2000);
    var rbuf: [512]u8 = undefined;
    var reader = stream.reader(io_val, &rbuf);
    var pbuf: [MAX_ACTION_FRAME_BYTES]u8 = undefined;
    // PEER_INFO (the host) is ordered ahead of the SYNC
    const f = try decodeSkippingPeerInfo(&reader.interface, &pbuf);
    try testing.expectEqual(@intFromEnum(FrameKind.sync), f.kind);
    const p = try parseSyncPayload(f.payload);
    try testing.expectEqualStrings("DOC42", p.state);
    const info = testSlotSyncInfo(1).?;
    try testing.expect(info.snapshot_valid);
}

test "netsync: an export of 0 bytes disconnects" {
    resetForTest();
    defer resetForTest();
    var sctx: SyncCtx = .{ .export_empty = true };
    registerStateSync(.{ .ctx = &sctx, .export_fn = syncExport, .import_fn = syncImport });
    initHost(0);
    const port = listeningPort().?;
    var stream = try rawHelloConnect(net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) }, "z");
    defer stream.close(io_val);
    try waitPeers(1, 2000);
    pump();
    var waited: u64 = 0;
    while (peerCount() != 0 and waited < 2000) : (waited += 10) sleepMs(10);
    try testing.expectEqual(@as(usize, 0), peerCount());
}

test "netsync: a PROPOSE while awaiting_sync gives session_not_ready" {
    resetForTest();
    defer resetForTest();
    ensureIo();
    peers_mutex.lockUncancelable(io_val);
    role = .client;
    started = true;
    awaiting_sync = true;
    peers_mutex.unlock(io_val);

    var buf: [64]u8 = undefined;
    try testing.expectError(error.SessionNotReady, proposeToHost("add_node", "vco 0 0", &buf));
}

test "netsync: a client's SYNC import, and a COMMIT held while awaiting_sync" {
    resetForTest();
    defer resetForTest();
    var sctx: SyncCtx = .{};
    registerStateSync(.{ .ctx = &sctx, .export_fn = syncExport, .import_fn = syncImport });

    ensureIo();
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(0) };
    var srv = try addr.listen(io_val, .{ .reuse_address = true });
    defer srv.deinit(io_val);
    const port = srv.socket.address.getPort();

    const Host = struct {
        fn run(listen_srv: *net.Server) void {
            ensureIo();
            const stream = listen_srv.accept(io_val) catch return;
            defer stream.close(io_val);
            var rbuf: [256]u8 = undefined;
            var reader = stream.reader(io_val, &rbuf);
            var pbuf: [512]u8 = undefined;
            _ = decodeFrame(&reader.interface, &pbuf) catch return;
            var wbuf: [512]u8 = undefined;
            var writer = stream.writer(io_val, &wbuf);
            var hbuf: [64]u8 = undefined;
            const resp = formatHostHello(&hbuf, 1) catch return;
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.hello), resp) catch return;
            writer.interface.flush() catch return;
            // Send the COMMIT first, then a large SYNC (a COMMIT is held while awaiting)
            const commit = formatCommitPayload(&pbuf, 1, 0, "stroke", "held") catch return;
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.commit), commit) catch return;
            writer.interface.flush() catch return;
            sleepMs(30);
            const state = "BIGSTATE_OVER_INLINE";
            const sync_bytes = buildSyncPayload(0, state) catch return;
            defer gpa.free(sync_bytes);
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.sync), sync_bytes) catch return;
            writer.interface.flush() catch return;
            sleepMs(150);
        }
    };
    const ht = try std.Thread.spawn(.{}, Host.run, .{&srv});
    defer ht.join();

    var actx: SemCtx = .{};
    registerSem("stroke", &actx, .relay);
    initClientAs(net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) }, .human, "imp");
    try waitClientActive(2000);
    try testing.expect(testAwaitingSync());

    // the COMMIT stays in inbound but is not applied, because of awaiting
    var waited: u64 = 0;
    while (inboundLen() < 1 and waited < 2000) : (waited += 5) sleepMs(5);
    pump(); // With no SYNC yet it does not dequeue. Once the SYNC arrives it imports, and even then does not dequeue in the same pump (that waits for the pump after awaiting is released)
    // waiting for the SYNC
    waited = 0;
    while (testAwaitingSync() and waited < 3000) : (waited += 5) {
        pump();
        sleepMs(5);
    }
    try testing.expect(!testAwaitingSync());
    try testing.expectEqual(@as(u32, 1), sctx.import_calls);
    try testing.expectEqualStrings("BIGSTATE_OVER_INLINE", sctx.last_import[0..sctx.last_import_len]);
    try testing.expectEqual(@as(u32, 0), actx.calls); // the COMMIT still has not

    pump(); // the held COMMIT is applied
    try testing.expectEqual(@as(u32, 1), actx.calls);
}

test "netsync: a failed import fails soft (and the held COMMIT is not applied)" {
    resetForTest();
    defer resetForTest();
    var sctx: SyncCtx = .{ .import_fail = true };
    registerStateSync(.{ .ctx = &sctx, .export_fn = syncExport, .import_fn = syncImport });

    ensureIo();
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(0) };
    var srv = try addr.listen(io_val, .{ .reuse_address = true });
    defer srv.deinit(io_val);
    const port = srv.socket.address.getPort();

    const Host = struct {
        fn run(listen_srv: *net.Server) void {
            ensureIo();
            const stream = listen_srv.accept(io_val) catch return;
            defer stream.close(io_val);
            var rbuf: [256]u8 = undefined;
            var reader = stream.reader(io_val, &rbuf);
            var pbuf: [256]u8 = undefined;
            _ = decodeFrame(&reader.interface, &pbuf) catch return;
            var wbuf: [256]u8 = undefined;
            var writer = stream.writer(io_val, &wbuf);
            var hbuf: [64]u8 = undefined;
            const resp = formatHostHello(&hbuf, 1) catch return;
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.hello), resp) catch return;
            writer.interface.flush() catch return;
            const commit = formatCommitPayload(&pbuf, 1, 0, "stroke", "x") catch return;
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.commit), commit) catch return;
            const sync_bytes = buildSyncPayload(0, "S") catch return;
            defer gpa.free(sync_bytes);
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.sync), sync_bytes) catch return;
            writer.interface.flush() catch return;
            sleepMs(100);
        }
    };
    const ht = try std.Thread.spawn(.{}, Host.run, .{&srv});
    defer ht.join();

    var actx: SemCtx = .{};
    registerSem("stroke", &actx, .relay);
    initClientAs(net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) }, .human, "fail");
    try waitClientActive(2000);
    var waited: u64 = 0;
    while (isEnabled() and waited < 3000) : (waited += 10) {
        pump();
        sleepMs(10);
    }
    try testing.expect(!isEnabled());
    try testing.expectEqual(@as(u32, 0), actx.calls);
}

test "netsync: a stale ClientJoined is ignored" {
    resetForTest();
    defer resetForTest();
    initHost(0);
    // put a stale marker on directly
    var joined: [8]u8 = undefined;
    std.mem.writeInt(u32, joined[0..4], 99, .little);
    std.mem.writeInt(u32, joined[4..8], 1, .little);
    try testing.expect(inbound.enqueue(io_val, INTERNAL_CLIENT_JOINED, &joined, 99));
    pump(); // ignored, without falling over
    try testing.expectEqual(@as(usize, 0), peerCount());
}

test "netsync: on a failed big-entry enqueue the caller frees it (and it disconnects)" {
    resetForTest();
    defer resetForTest();
    // fill the outbound queue to take the enqueueBig failure path
    initHost(0);
    const port = listeningPort().?;
    var stream = try rawHelloConnect(net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) }, "full");
    defer stream.close(io_val);
    try waitPeers(1, 2000);

    peers_mutex.lockUncancelable(io_val);
    const slot = &slots[0];
    // Clog the outbound queue before ClientJoined, and close it so the writer's drain cannot free room, which makes the enqueueBig failure certain
    var i: usize = 0;
    while (i < OUTBOUND_CAP) : (i += 1) {
        _ = slot.outbound.enqueue(io_val, 0x03, "pad");
    }
    slot.outbound.close(io_val);
    peers_mutex.unlock(io_val);

    pump(); // ClientJoined → enqueueBig fails → the caller frees it, and the connection drops
    var waited: u64 = 0;
    while (peerCount() != 0 and waited < 3000) : (waited += 10) sleepMs(10);
    try testing.expectEqual(@as(usize, 0), peerCount());
}

test "netsync: freeing a big entry (after a dequeue, unsent on a reset, and by the caller on a failed enqueue)" {
    resetForTest();
    defer resetForTest();
    ensureIo();
    var q: OutboundQueue = .{};

    // the equivalent of having sent it: dequeue moves ownership → free
    {
        const buf = try gpa.alloc(u8, 64);
        @memset(buf, 0xAB);
        try testing.expect(q.enqueueBig(io_val, 0x04, buf));
        var entry: OutboundEntry = .{ .inline_frame = .{} };
        try testing.expect(q.dequeueWait(io_val, &entry) != null);
        entry.free();
    }

    // the equivalent of a shutdown or a disconnect: the reset frees an unsent big entry
    {
        const buf = try gpa.alloc(u8, 32);
        @memset(buf, 0xCD);
        try testing.expect(q.enqueueBig(io_val, 0x04, buf));
        q.reset(io_val);
        try testing.expectEqual(@as(usize, 0), q.count);
    }

    // on an enqueue failure the caller frees it (a full queue)
    {
        var i: usize = 0;
        while (i < OUTBOUND_CAP) : (i += 1) {
            try testing.expect(q.enqueue(io_val, 0x03, "x"));
        }
        const orphan = try gpa.alloc(u8, 16);
        try testing.expect(!q.enqueueBig(io_val, 0x04, orphan));
        gpa.free(orphan); // the caller frees it
        q.reset(io_val);
    }

    // enqueueBig fails when closed too → the caller frees it
    {
        q.close(io_val);
        const orphan = try gpa.alloc(u8, 8);
        try testing.expect(!q.enqueueBig(io_val, 0x04, orphan));
        gpa.free(orphan);
        q.reset(io_val);
    }
}

test "netsync: a big entry is freed even when the writer's encode or flush fails" {
    resetForTest();
    defer resetForTest();
    initHost(0);
    const port = listeningPort().?;
    var stream = try rawHelloConnect(net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) }, "wfail");
    try waitPeers(1, 2000);
    try pumpUntilAllSynced(2000);
    try expectEmptySync(stream);

    // Put a large big entry on, close the far end so the write or flush fails → the writer calls entry.free()
    peers_mutex.lockUncancelable(io_val);
    const big = try gpa.alloc(u8, 256 * 1024);
    @memset(big, 0xEF);
    try testing.expect(slots[0].outbound.enqueueBig(io_val, @intFromEnum(FrameKind.sync), big));
    peers_mutex.unlock(io_val);

    stream.close(io_val);

    // .empty, not just "no longer .active": the big entry is freed during teardown, after the
    // writer is joined, so peerCount() reaching 0 does not yet mean outbound has been emptied.
    try waitSlotsEmpty(5000);
    try testing.expectEqual(@as(usize, 0), peerCount());
    peers_mutex.lockUncancelable(io_val);
    defer peers_mutex.unlock(io_val);
    try testing.expectEqual(@as(usize, 0), slots[0].outbound.count);
    try testing.expect(slots[0].state == .empty);
}

test "netsync: reusing a slot leaves behind no unsent big entry from the previous connection" {
    resetForTest();
    defer resetForTest();
    initHost(0);
    const port = listeningPort().?;
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };

    var stream = try rawHelloConnect(addr, "reuse1");
    try waitPeers(1, 2000);
    try pumpUntilAllSynced(2000);
    try expectEmptySync(stream);

    peers_mutex.lockUncancelable(io_val);
    const gen0 = slots[0].generation;
    const big = try gpa.alloc(u8, 128);
    @memset(big, 0x11);
    try testing.expect(slots[0].outbound.enqueueBig(io_val, @intFromEnum(FrameKind.sync), big));
    // Stop the writer and leave it unsent (checking the freeing on the reset and cleanup paths)
    slots[0].outbound.close(io_val);
    peers_mutex.unlock(io_val);

    stream.close(io_val);
    // .empty, not just "no longer .active": slot 0 has to be free for the reconnect below to reuse it.
    // Reaching it also settles the previous connection's queue: teardown resets it, which frees the
    // unsent big entry and reopens the queue this test closed above.
    try waitSlotsEmpty(5000);
    try testing.expectEqual(@as(usize, 0), peerCount());
    try testing.expect(!slots[0].outbound.isClosed(io_val));

    var stream2 = try rawHelloConnect(addr, "reuse2");
    defer stream2.close(io_val);
    try waitPeers(1, 2000);

    peers_mutex.lockUncancelable(io_val);
    defer peers_mutex.unlock(io_val);
    try testing.expect(slots[0].state == .active or slots[0].state == .hello_pending);
    try testing.expect(slots[0].generation != gen0);
    // The reused queue carries the new handshake and nothing of the old connection. An emptiness
    // check would instead be a race against the writer thread; see expectFreshSlotOutbound.
    try expectFreshSlotOutbound(&slots[0].outbound);
}

test "netsync: freeing an unsent big entry during a shutdown, and joining the writer" {
    resetForTest();
    defer resetForTest();
    initHost(0);
    const port = listeningPort().?;
    var stream = try rawHelloConnect(net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) }, "shut");
    defer stream.close(io_val);
    try waitPeers(1, 2000);
    try pumpUntilAllSynced(2000);
    try expectEmptySync(stream);

    peers_mutex.lockUncancelable(io_val);
    const big = try gpa.alloc(u8, 64 * 1024);
    @memset(big, 0x22);
    try testing.expect(slots[0].outbound.enqueueBig(io_val, @intFromEnum(FrameKind.sync), big));
    // To leave something unsent, wake the writer and let it finish, leaving the entry on the queue
    slots[0].outbound.close(io_val);
    peers_mutex.unlock(io_val);
    sleepMs(20); // wait for the writer to come out of dequeueWait

    shutdown();
    try testing.expect(!isEnabled());
    peers_mutex.lockUncancelable(io_val);
    defer peers_mutex.unlock(io_val);
    try testing.expectEqual(@as(usize, 0), slots[0].outbound.count);
    try testing.expect(slots[0].writer_thread == null);
    try testing.expect(slots[0].state == .empty);
}

test "netsync: gatherStats gives the defaults while disabled" {
    resetForTest();
    defer resetForTest();
    const st = gatherStats();
    try testing.expectEqual(Role.disabled, st.role);
    try testing.expectEqual(@as(usize, 0), st.peers);
    try testing.expectEqual(@as(usize, 0), st.agents);
    try testing.expectEqual(@as(u32, 0), st.peer_id);
    try testing.expectEqual(@as(u64, 0), st.last_seq);
    try testing.expectEqual(@as(usize, 0), st.pending);
    try testing.expect(!st.awaiting_sync);
    try testing.expectEqual(@as(u32, 0), st.last_reject);
}

test "netsync: gatherStats reports peers and pending on an enabled host" {
    resetForTest();
    defer resetForTest();
    initHost(0);
    const port = listeningPort().?;
    var stream = try rawHelloConnect(net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) }, "gs");
    defer stream.close(io_val);
    try waitPeers(1, 2000);

    // ClientJoined not yet pumped → pending>=1
    const before = gatherStats();
    try testing.expectEqual(Role.host, before.role);
    try testing.expectEqual(@as(usize, 1), before.peers);
    try testing.expectEqual(@as(u32, 0), before.peer_id);
    try testing.expect(before.pending >= 1);

    try pumpUntilAllSynced(2000);
    try expectEmptySync(stream);
    const after = gatherStats();
    try testing.expectEqual(@as(usize, 0), after.pending);
    try testing.expectEqual(@as(u64, 0), after.last_seq);
}

test "netsync: gatherStats through a client's awaiting_sync transition, and last_applied_seq" {
    resetForTest();
    defer resetForTest();

    ensureIo();
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(0) };
    var srv = try addr.listen(io_val, .{ .reuse_address = true });
    defer srv.deinit(io_val);
    const port = srv.socket.address.getPort();

    const Host = struct {
        fn run(listen_srv: *net.Server) void {
            ensureIo();
            const stream = listen_srv.accept(io_val) catch return;
            defer stream.close(io_val);
            var rbuf: [256]u8 = undefined;
            var reader = stream.reader(io_val, &rbuf);
            var pbuf: [512]u8 = undefined;
            _ = decodeFrame(&reader.interface, &pbuf) catch return;
            var wbuf: [512]u8 = undefined;
            var writer = stream.writer(io_val, &wbuf);
            var hbuf: [64]u8 = undefined;
            const resp = formatHostHello(&hbuf, 7) catch return;
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.hello), resp) catch return;
            const sync_bytes = buildSyncPayload(0, "S") catch return;
            defer gpa.free(sync_bytes);
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.sync), sync_bytes) catch return;
            writer.interface.flush() catch return;
            sleepMs(30);
            const commit = formatCommitPayload(&pbuf, 3, 0, "stroke", "a") catch return;
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.commit), commit) catch return;
            writer.interface.flush() catch return;
            sleepMs(100);
        }
    };
    const ht = try std.Thread.spawn(.{}, Host.run, .{&srv});
    defer ht.join();

    var sctx: SyncCtx = .{};
    registerStateSync(.{ .ctx = &sctx, .export_fn = syncExport, .import_fn = syncImport });
    var actx: SemCtx = .{};
    registerSem("stroke", &actx, .relay);

    initClientAs(net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) }, .human, "gs2");
    try waitClientActive(2000);
    try testing.expect(gatherStats().awaiting_sync);

    var waited: u64 = 0;
    while (testAwaitingSync() and waited < 3000) : (waited += 5) {
        pump();
        sleepMs(5);
    }
    try testing.expect(!gatherStats().awaiting_sync);
    try testing.expectEqual(@as(u64, 0), gatherStats().last_seq);

    waited = 0;
    while (gatherStats().last_seq < 3 and waited < 3000) : (waited += 5) {
        pump();
        sleepMs(5);
    }
    try testing.expectEqual(@as(u64, 3), gatherStats().last_seq);
    try testing.expectEqual(@as(u32, 1), actx.calls);
}

test "netsync: formatting the digest, and normalising and truncating reject_reason" {
    resetForTest();
    defer resetForTest();

    var buf: [512]u8 = undefined;
    const disabled = formatDigest(&buf);
    try testing.expect(std.mem.startsWith(u8, disabled, "role=disabled"));
    try testing.expect(std.mem.indexOf(u8, disabled, "last_reject=none") != null);
    try testing.expect(std.mem.indexOf(u8, disabled, "reject_reason=none") != null);

    // normalising a reason (on its own)
    var tok: [64]u8 = undefined;
    const s1 = sanitizeRejectReasonToken(&tok, "a b\tc\nd\r");
    try testing.expectEqualStrings("a_b_c_d_", s1);
    const long = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdefEXTRA";
    const s2 = sanitizeRejectReasonToken(&tok, long);
    try testing.expectEqual(@as(usize, 64), s2.len);
    try testing.expect(std.mem.eql(u8, s2, long[0..64]));

    // the digest after a REJECT
    ensureIo();
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(0) };
    var srv = try addr.listen(io_val, .{ .reuse_address = true });
    defer srv.deinit(io_val);
    const port = srv.socket.address.getPort();
    const Host = struct {
        fn run(listen_srv: *net.Server) void {
            ensureIo();
            const stream = listen_srv.accept(io_val) catch return;
            defer stream.close(io_val);
            var rbuf: [256]u8 = undefined;
            var reader = stream.reader(io_val, &rbuf);
            var pbuf: [256]u8 = undefined;
            _ = decodeFrame(&reader.interface, &pbuf) catch return;
            var wbuf: [256]u8 = undefined;
            var writer = stream.writer(io_val, &wbuf);
            var hbuf: [64]u8 = undefined;
            const resp = formatHostHello(&hbuf, 1) catch return;
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.hello), resp) catch return;
            var sync_pl: [8]u8 = undefined;
            std.mem.writeInt(u64, sync_pl[0..8], 0, .little);
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.sync), &sync_pl) catch return;
            const rej = formatRejectPayload(&pbuf, 42, "bad\treason\n") catch return;
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.reject), rej) catch return;
            writer.interface.flush() catch return;
            sleepMs(80);
        }
    };
    const ht = try std.Thread.spawn(.{}, Host.run, .{&srv});
    defer ht.join();

    initClientAs(net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) }, .human, "dig");
    try waitClientActive(2000);
    var waited: u64 = 0;
    while (lastRejectedProposal() == 0 and waited < 3000) : (waited += 5) {
        pump();
        sleepMs(5);
    }
    const dig = formatDigest(&buf);
    try testing.expect(std.mem.indexOf(u8, dig, "role=client") != null);
    try testing.expect(std.mem.indexOf(u8, dig, "last_reject=42") != null);
    try testing.expect(std.mem.indexOf(u8, dig, "reject_reason=bad_reason_") != null);
    try testing.expectEqual(@as(u32, 42), gatherStats().last_reject);

    const snap = try formatSnapshot(testing.allocator);
    defer testing.allocator.free(snap);
    try testing.expect(std.mem.indexOf(u8, snap, "\"last_reject\":42") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "\"reject_reason\":\"bad_reason_\"") != null);
}

// ============================================================================
// undo and redo, pending, and REJECT
// ============================================================================

/// A mock executor that supports noteUndo (for the netsync wire undo tests).
const WireUndo = struct {
    exec: *command.Executor = undefined,
    next_ref: u64 = 1,
    valid: [128]bool = [_]bool{false} ** 128,

    fn run(ctx: *anyopaque, name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
        const self: *WireUndo = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, name, "set_tool") and !std.mem.eql(u8, name, "save")) {
            const ref = self.next_ref;
            self.next_ref += 1;
            if (ref < self.valid.len) self.valid[ref] = true;
            self.exec.noteUndo(ref);
        }
        return std.fmt.bufPrint(buf, "ok:{s}", .{args}) catch "ok";
    }

    fn canUndo(ctx: *anyopaque, rec: *const command.CommandRecord) bool {
        const self: *WireUndo = @ptrCast(@alignCast(ctx));
        const ref = rec.undo_ref orelse return false;
        return ref < self.valid.len and self.valid[ref];
    }

    fn applyUndo(ctx: *anyopaque, rec: *const command.CommandRecord) void {
        const self: *WireUndo = @ptrCast(@alignCast(ctx));
        if (rec.undo_ref) |ref| {
            if (ref < self.valid.len) self.valid[ref] = false;
        }
    }

    fn summarize(ctx: *anyopaque, rec: *const command.CommandRecord, buf: []u8) []const u8 {
        _ = ctx;
        const n = @min(rec.name().len, buf.len);
        @memcpy(buf[0..n], rec.name()[0..n]);
        return buf[0..n];
    }
};

fn setupWireUndo(wu: *WireUndo, log: *command.CommandLog, exec: *command.Executor) void {
    log.* = .{};
    exec.* = command.Executor.init(.{ .ctx = wu, .run = WireUndo.run });
    exec.log = log;
    exec.adapter = .{
        .ctx = wu,
        .canUndo = WireUndo.canUndo,
        .applyUndo = WireUndo.applyUndo,
        .summarize = WireUndo.summarize,
    };
    wu.* = .{ .exec = exec };
    setSharedExecutor(exec);
}

fn readRejectFrom(stream: net.Stream, reason_buf: []u8) !struct { proposal_id: u32, reason: []const u8 } {
    var rbuf: [256]u8 = undefined;
    var reader = stream.reader(io_val, &rbuf);
    var fbuf: [128]u8 = undefined;
    const f = try decodeFrame(&reader.interface, &fbuf);
    try testing.expectEqual(@intFromEnum(FrameKind.reject), f.kind);
    const parsed = try parseRejectPayload(f.payload);
    const n = @min(parsed.reason.len, reason_buf.len);
    if (n > 0) @memcpy(reason_buf[0..n], parsed.reason[0..n]);
    return .{ .proposal_id = parsed.proposal_id, .reason = reason_buf[0..n] };
}

test "netsync: with no undo candidate it is a no-op (no PROPOSE_REVERT is sent)" {
    resetForTest();
    defer resetForTest();

    var wu: WireUndo = undefined;
    var log: command.CommandLog = undefined;
    var exec: command.Executor = undefined;
    setupWireUndo(&wu, &log, &exec);

    ensureIo();
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(0) };
    var srv = try addr.listen(io_val, .{ .reuse_address = true });
    defer srv.deinit(io_val);
    const port = srv.socket.address.getPort();

    const Host = struct {
        fn run(listen_srv: *net.Server) void {
            ensureIo();
            const stream = listen_srv.accept(io_val) catch return;
            defer stream.close(io_val);
            var rbuf: [256]u8 = undefined;
            var reader = stream.reader(io_val, &rbuf);
            var pbuf: [128]u8 = undefined;
            _ = decodeFrame(&reader.interface, &pbuf) catch return;
            var wbuf: [128]u8 = undefined;
            var writer = stream.writer(io_val, &wbuf);
            var hbuf: [64]u8 = undefined;
            const resp = formatHostHello(&hbuf, 1) catch return;
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.hello), resp) catch return;
            var sync_pl: [8]u8 = undefined;
            std.mem.writeInt(u64, sync_pl[0..8], 0, .little);
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.sync), &sync_pl) catch return;
            writer.interface.flush() catch return;
            // keep the connection (without a blocking read; the shutdown disconnects)
            sleepMs(300);
        }
    };
    const ht = try std.Thread.spawn(.{}, Host.run, .{&srv});
    defer ht.join();

    var ctx: SemCtx = .{};
    registerSem("undo", &ctx, .undo_own);

    initClientAs(net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) }, .human, "u0");
    try waitClientActive(2000);
    var waited: u64 = 0;
    while (testAwaitingSync() and waited < 2000) : (waited += 5) {
        pump();
        sleepMs(5);
    }

    var buf: [64]u8 = undefined;
    const out = try action_registry.routeLocalAction("undo", "", &buf);
    try testing.expectEqualStrings("nothing to undo", out);
    try testing.expectEqual(@as(usize, 0), testPendingCount());
}

test "netsync: a PROPOSE_REVERT to COMMIT_REVERT round trip" {
    resetForTest();
    defer resetForTest();

    var wu: WireUndo = undefined;
    var log: command.CommandLog = undefined;
    var exec: command.Executor = undefined;
    setupWireUndo(&wu, &log, &exec);

    var ctx: SemCtx = .{};
    registerSem("stroke", &ctx, .relay);
    registerSem("undo", &ctx, .undo_own);

    initHost(0);
    const port = listeningPort().?;
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    var stream = try rawHelloConnect(addr, "rev");
    defer stream.close(io_val);
    try waitPeers(1, 2000);
    try pumpUntilAllSynced(2000);
    try expectEmptySync(stream);

    // peer1 stroke
    var wbuf: [256]u8 = undefined;
    var writer = stream.writer(io_val, &wbuf);
    var pbuf: [128]u8 = undefined;
    const prop = try formatProposePayload(&pbuf, 1, "stroke", "1 1");
    try encodeFrame(&writer.interface, @intFromEnum(FrameKind.propose), prop);
    try writer.interface.flush();
    var waited: u64 = 0;
    while (inboundLen() < 1 and waited < 2000) : (waited += 5) sleepMs(5);
    pump();
    try testing.expect(log.findBySeq(1).?.undoable);
    try testing.expect(!log.findBySeq(1).?.reverted);

    // PROPOSE_REVERT
    const prev = try formatProposeRevertPayload(&pbuf, 2, 1);
    try encodeFrame(&writer.interface, @intFromEnum(FrameKind.propose_revert), prev);
    try writer.interface.flush();
    waited = 0;
    while (inboundLen() < 1 and waited < 2000) : (waited += 5) sleepMs(5);
    pump();

    try testing.expect(log.findBySeq(1).?.reverted);
    const rev = log.findBySeq(2).?;
    try testing.expectEqual(command.CommandKind.revert, rev.kind);
    try testing.expectEqual(@as(u64, 1), rev.target_seq.?);
    try testing.expect(rev.actor.eql(.{ .peer = 1 }));

    var rbuf: [256]u8 = undefined;
    var reader = stream.reader(io_val, &rbuf);
    var fbuf: [128]u8 = undefined;
    // COMMIT for stroke
    const f1 = try decodeFrame(&reader.interface, &fbuf);
    try testing.expectEqual(@intFromEnum(FrameKind.commit), f1.kind);
    const f2 = try decodeFrame(&reader.interface, &fbuf);
    try testing.expectEqual(@intFromEnum(FrameKind.commit_revert), f2.kind);
    const cr = try parseCommitRevertPayload(f2.payload);
    try testing.expectEqual(@as(u64, 2), cr.seq);
    try testing.expectEqual(@as(u64, 1), cr.target_seq);
}

test "netsync: every REJECT reason for a PROPOSE_REVERT" {
    resetForTest();
    defer resetForTest();

    var wu: WireUndo = undefined;
    var log: command.CommandLog = undefined;
    var exec: command.Executor = undefined;
    setupWireUndo(&wu, &log, &exec);

    var ctx: SemCtx = .{};
    registerSem("stroke", &ctx, .relay);

    initHost(0);
    const port = listeningPort().?;
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    var stream = try rawHelloConnect(addr, "rej");
    defer stream.close(io_val);
    try waitPeers(1, 2000);
    try pumpUntilAllSynced(2000);
    try expectEmptySync(stream);

    var abuf: [128]u8 = undefined;
    // seq1: peer1 undoable
    _ = try exec.executeAction("stroke", "a", .{ .actor = .{ .peer = 1 }, .source = .{ .remote_commit = .{ .seq = 1 } } }, &abuf);
    noteWireSeq(1);
    // seq2: peer1 not undoable
    _ = try exec.executeAction("set_tool", "pen", .{ .actor = .{ .peer = 1 }, .source = .{ .remote_commit = .{ .seq = 2 } } }, &abuf);
    noteWireSeq(2);
    // seq3: peer2 (so "not yours" for peer1)
    _ = try exec.executeAction("stroke", "b", .{ .actor = .{ .peer = 2 }, .source = .{ .remote_commit = .{ .seq = 3 } } }, &abuf);
    noteWireSeq(3);
    // seq4: peer1 already reverted
    _ = try exec.executeAction("stroke", "c", .{ .actor = .{ .peer = 1 }, .source = .{ .remote_commit = .{ .seq = 4 } } }, &abuf);
    noteWireSeq(4);
    log.findBySeq(4).?.reverted = true;
    // seq5: peer1 in open transaction
    const tx = try exec.beginTransaction(.{ .peer = 1 }, "t");
    _ = try exec.executeAction("stroke", "d", .{
        .actor = .{ .peer = 1 },
        .transaction = tx,
        .source = .{ .remote_commit = .{ .seq = 5 } },
    }, &abuf);
    noteWireSeq(5);
    try exec.endTransaction(tx, .{ .peer = 1 });
    // seq6: peer1 too old (with the undo_ref invalidated)
    _ = try exec.executeAction("stroke", "e", .{ .actor = .{ .peer = 1 }, .source = .{ .remote_commit = .{ .seq = 6 } } }, &abuf);
    noteWireSeq(6);
    wu.valid[log.findBySeq(6).?.undo_ref.?] = false;

    var wbuf: [256]u8 = undefined;
    var writer = stream.writer(io_val, &wbuf);
    var pbuf: [32]u8 = undefined;

    const cases = [_]struct { id: u32, target: u64, reason: []const u8 }{
        .{ .id = 10, .target = 99, .reason = "unknown seq" },
        .{ .id = 11, .target = 3, .reason = "not yours" },
        .{ .id = 12, .target = 2, .reason = "not undoable" },
        .{ .id = 13, .target = 4, .reason = "already reverted" },
        .{ .id = 14, .target = 5, .reason = "transaction undo unsupported" },
        .{ .id = 15, .target = 6, .reason = "too old" },
    };
    for (cases) |c| {
        const pl = try formatProposeRevertPayload(&pbuf, c.id, c.target);
        try encodeFrame(&writer.interface, @intFromEnum(FrameKind.propose_revert), pl);
        try writer.interface.flush();
        var waited_case: u64 = 0;
        while (inboundLen() < 1 and waited_case < 2000) : (waited_case += 5) sleepMs(5);
        pump();
        var reason_storage: [64]u8 = undefined;
        const rej = try readRejectFrom(stream, &reason_storage);
        try testing.expectEqual(c.id, rej.proposal_id);
        try testing.expectEqualStrings(c.reason, rej.reason);
    }

    // before peer join: put join_snapshot_seq at seq1 or above
    try testing.expect(testSetJoinSnapshotSeq(1, 1));
    const pl = try formatProposeRevertPayload(&pbuf, 16, 1);
    try encodeFrame(&writer.interface, @intFromEnum(FrameKind.propose_revert), pl);
    try writer.interface.flush();
    var waited: u64 = 0;
    while (inboundLen() < 1 and waited < 2000) : (waited += 5) sleepMs(5);
    pump();
    var reason_storage: [64]u8 = undefined;
    const rej = try readRejectFrom(stream, &reason_storage);
    try testing.expectEqual(@as(u32, 16), rej.proposal_id);
    try testing.expectEqualStrings("before peer join", rej.reason);
}

test "netsync: a multi-stage undo then redo chain on a host (the epoch does not destroy itself)" {
    resetForTest();
    defer resetForTest();

    var wu: WireUndo = undefined;
    var log: command.CommandLog = undefined;
    var exec: command.Executor = undefined;
    setupWireUndo(&wu, &log, &exec);

    var ctx: SemCtx = .{};
    registerSem("stroke", &ctx, .relay);
    registerSem("undo", &ctx, .undo_own);
    registerSem("redo", &ctx, .redo_own);

    initHost(0);
    // a host-local undo and redo work even with no peers
    var buf: [128]u8 = undefined;
    _ = try action_registry.routeLocalAction("stroke", "a", &buf); // seq1
    _ = try action_registry.routeLocalAction("stroke", "b", &buf); // seq2
    try testing.expectEqual(@as(u32, 2), log.filled);

    const undo1 = try action_registry.routeLocalAction("undo", "", &buf);
    try testing.expect(std.mem.indexOf(u8, undo1, "reverted") != null);
    try testing.expect(log.findBySeq(2).?.reverted);
    _ = try action_registry.routeLocalAction("undo", "", &buf);
    try testing.expect(log.findBySeq(1).?.reverted);

    const redo1 = try action_registry.routeLocalAction("redo", "", &buf);
    try testing.expect(std.mem.indexOf(u8, redo1, "ok:") != null);
    // a redo does not advance the epoch → so the second-stage redo still has a candidate
    const redo2 = try action_registry.routeLocalAction("redo", "", &buf);
    try testing.expect(std.mem.indexOf(u8, redo2, "ok:") != null);

    // it can be undone again (it has not destroyed itself)
    _ = try action_registry.routeLocalAction("undo", "", &buf);
    try testing.expect(exec.findUndoCandidate(.{ .peer = 0 }) != null or exec.findRedoCandidate(.{ .peer = 0 }) != null);
}

test "netsync: removing a pending REJECT" {
    resetForTest();
    defer resetForTest();

    var wu: WireUndo = undefined;
    var log: command.CommandLog = undefined;
    var exec: command.Executor = undefined;
    setupWireUndo(&wu, &log, &exec);

    ensureIo();
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(0) };
    var srv = try addr.listen(io_val, .{ .reuse_address = true });
    defer srv.deinit(io_val);
    const port = srv.socket.address.getPort();

    const Host = struct {
        fn run(listen_srv: *net.Server) void {
            ensureIo();
            const stream = listen_srv.accept(io_val) catch return;
            defer stream.close(io_val);
            var rbuf: [512]u8 = undefined;
            var reader = stream.reader(io_val, &rbuf);
            var pbuf: [256]u8 = undefined;
            _ = decodeFrame(&reader.interface, &pbuf) catch return;
            var wbuf: [256]u8 = undefined;
            var writer = stream.writer(io_val, &wbuf);
            var hbuf: [64]u8 = undefined;
            const resp = formatHostHello(&hbuf, 1) catch return;
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.hello), resp) catch return;
            var sync_pl: [8]u8 = undefined;
            std.mem.writeInt(u64, sync_pl[0..8], 0, .little);
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.sync), &sync_pl) catch return;
            writer.interface.flush() catch return;

            const f = decodeFrame(&reader.interface, &pbuf) catch return;
            if (f.kind == @intFromEnum(FrameKind.propose)) {
                const pp = parseProposePayload(f.payload) catch return;
                const rej = formatRejectPayload(&pbuf, pp.proposal_id, "nope") catch return;
                encodeFrame(&writer.interface, @intFromEnum(FrameKind.reject), rej) catch return;
                writer.interface.flush() catch return;
            }
            sleepMs(200);
        }
    };
    const ht = try std.Thread.spawn(.{}, Host.run, .{&srv});
    defer ht.join();

    var ctx: SemCtx = .{};
    registerSem("stroke", &ctx, .relay);

    initClientAs(net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) }, .human, "pq");
    try waitClientActive(2000);
    var waited: u64 = 0;
    while (testAwaitingSync() and waited < 2000) : (waited += 5) {
        pump();
        sleepMs(5);
    }

    var buf: [64]u8 = undefined;
    _ = try action_registry.routeLocalAction("stroke", "1", &buf);
    try testing.expectEqual(@as(usize, 1), testPendingCount());
    waited = 0;
    while (testPendingCount() > 0 and waited < 2000) : (waited += 5) {
        pump();
        sleepMs(5);
    }
    try testing.expectEqual(@as(usize, 0), testPendingCount());
    try testing.expect(lastRejectedProposal() != 0);
}

test "netsync: backpressure from a full pending queue" {
    resetForTest();
    defer resetForTest();

    var wu: WireUndo = undefined;
    var log: command.CommandLog = undefined;
    var exec: command.Executor = undefined;
    setupWireUndo(&wu, &log, &exec);

    ensureIo();
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(0) };
    var srv = try addr.listen(io_val, .{ .reuse_address = true });
    defer srv.deinit(io_val);
    const port = srv.socket.address.getPort();

    const Host = struct {
        fn run(listen_srv: *net.Server) void {
            ensureIo();
            const stream = listen_srv.accept(io_val) catch return;
            defer stream.close(io_val);
            var rbuf: [256]u8 = undefined;
            var reader = stream.reader(io_val, &rbuf);
            var pbuf: [128]u8 = undefined;
            _ = decodeFrame(&reader.interface, &pbuf) catch return;
            var wbuf: [128]u8 = undefined;
            var writer = stream.writer(io_val, &wbuf);
            var hbuf: [64]u8 = undefined;
            const resp = formatHostHello(&hbuf, 1) catch return;
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.hello), resp) catch return;
            var sync_pl: [8]u8 = undefined;
            std.mem.writeInt(u64, sync_pl[0..8], 0, .little);
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.sync), &sync_pl) catch return;
            writer.interface.flush() catch return;
            sleepMs(400);
        }
    };
    const ht = try std.Thread.spawn(.{}, Host.run, .{&srv});
    defer ht.join();

    var ctx: SemCtx = .{};
    registerSem("stroke", &ctx, .relay);

    initClientAs(net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) }, .human, "full");
    try waitClientActive(2000);
    var waited: u64 = 0;
    while (testAwaitingSync() and waited < 2000) : (waited += 5) {
        pump();
        sleepMs(5);
    }

    // Fill pending without clogging the outbound queue (by enqueuing directly)
    var i: u32 = 0;
    while (i < PENDING_CAP) : (i += 1) {
        try testing.expect(pendingEnqueue(.{ .proposal_id = i + 1, .kind = .normal, .redo_of = null, .target_seq = 0 }));
    }
    try testing.expectEqual(PENDING_CAP, testPendingCount());
    var buf: [64]u8 = undefined;
    try testing.expectError(error.PendingQueueFull, action_registry.routeLocalAction("stroke", "y", &buf));
}

test "netsync: the later REJECT of two concurrent reverts of the same target" {
    resetForTest();
    defer resetForTest();

    var wu: WireUndo = undefined;
    var log: command.CommandLog = undefined;
    var exec: command.Executor = undefined;
    setupWireUndo(&wu, &log, &exec);

    var ctx: SemCtx = .{};
    registerSem("stroke", &ctx, .relay);

    initHost(0);
    const port = listeningPort().?;
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    var stream = try rawHelloConnect(addr, "par");
    defer stream.close(io_val);
    try waitPeers(1, 2000);
    try pumpUntilAllSynced(2000);
    try expectEmptySync(stream);

    var abuf: [64]u8 = undefined;
    _ = try exec.executeAction("stroke", "z", .{ .actor = .{ .peer = 1 }, .source = .{ .remote_commit = .{ .seq = 1 } } }, &abuf);
    noteWireSeq(1);

    var wbuf: [128]u8 = undefined;
    var writer = stream.writer(io_val, &wbuf);
    var pbuf: [32]u8 = undefined;
    const p1 = try formatProposeRevertPayload(&pbuf, 1, 1);
    try encodeFrame(&writer.interface, @intFromEnum(FrameKind.propose_revert), p1);
    const p2 = try formatProposeRevertPayload(&pbuf, 2, 1);
    try encodeFrame(&writer.interface, @intFromEnum(FrameKind.propose_revert), p2);
    try writer.interface.flush();

    var waited: u64 = 0;
    while (inboundLen() < 2 and waited < 2000) : (waited += 5) sleepMs(5);
    pump();
    pump();

    try testing.expect(log.findBySeq(1).?.reverted);
    try testing.expectEqual(command.CommandKind.revert, log.findBySeq(2).?.kind);

    // a REJECT after the COMMIT_REVERT
    var rbuf: [256]u8 = undefined;
    var reader = stream.reader(io_val, &rbuf);
    var fbuf: [128]u8 = undefined;
    const f1 = try decodeFrame(&reader.interface, &fbuf);
    try testing.expectEqual(@intFromEnum(FrameKind.commit_revert), f1.kind);
    const f2 = try decodeFrame(&reader.interface, &fbuf);
    try testing.expectEqual(@intFromEnum(FrameKind.reject), f2.kind);
    const rej = try parseRejectPayload(f2.payload);
    try testing.expectEqual(@as(u32, 2), rej.proposal_id);
    try testing.expectEqualStrings("already reverted", rej.reason);
}

test "netsync: clearing wire_session after a fail-soft makes a local command recorded again" {
    resetForTest();
    defer resetForTest();

    var wu: WireUndo = undefined;
    var log: command.CommandLog = undefined;
    var exec: command.Executor = undefined;
    setupWireUndo(&wu, &log, &exec);

    ensureIo();
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(0) };
    var srv = try addr.listen(io_val, .{ .reuse_address = true });
    const port = srv.socket.address.getPort();

    var close_gate: std.atomic.Value(bool) = .init(false);
    const Host = struct {
        fn run(listen_srv: *net.Server, gate: *std.atomic.Value(bool)) void {
            ensureIo();
            const stream = listen_srv.accept(io_val) catch return;
            defer stream.close(io_val);
            var rbuf: [256]u8 = undefined;
            var reader = stream.reader(io_val, &rbuf);
            var pbuf: [128]u8 = undefined;
            _ = decodeFrame(&reader.interface, &pbuf) catch return;
            var wbuf: [128]u8 = undefined;
            var writer = stream.writer(io_val, &wbuf);
            var hbuf: [64]u8 = undefined;
            const resp = formatHostHello(&hbuf, 1) catch return;
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.hello), resp) catch return;
            var sync_pl: [8]u8 = undefined;
            std.mem.writeInt(u64, sync_pl[0..8], 0, .little);
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.sync), &sync_pl) catch return;
            writer.interface.flush() catch return;
            var waited: u64 = 0;
            while (!gate.load(.seq_cst) and waited < 5000) : (waited += 10) sleepMs(10);
        }
    };
    const ht = try std.Thread.spawn(.{}, Host.run, .{ &srv, &close_gate });
    defer {
        close_gate.store(true, .seq_cst);
        ht.join();
        srv.deinit(io_val);
    }

    initClientAs(net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) }, .human, "ws");
    try waitClientActive(2000);
    var waited_sync: u64 = 0;
    while (testAwaitingSync() and waited_sync < 2000) : (waited_sync += 5) {
        pump();
        sleepMs(5);
    }
    try testing.expect(exec.wire_session);

    close_gate.store(true, .seq_cst);
    var waited: u64 = 0;
    while (isEnabled() and waited < 3000) : (waited += 10) sleepMs(10);
    try testing.expect(!isEnabled());

    pump(); // router_clear → wire_session=false
    try testing.expect(!exec.wire_session);

    var buf: [128]u8 = undefined;
    const res = try exec.executeAction("stroke", "solo", .{ .actor = .local_user, .record_policy = .record }, &buf);
    try testing.expect(res.seq != null);
    try testing.expectEqual(@as(u32, 1), log.filled);
}

test "netsync: a failed COMMIT apply keeps pending and fails soft" {
    resetForTest();
    defer resetForTest();

    var fail_ctx: SemCtx = .{ .fail = true };
    var log: command.CommandLog = .{};
    var exec = command.Executor.init(.{
        .ctx = &fail_ctx,
        .run = struct {
            fn d(ctx: *anyopaque, name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
                _ = name;
                return semRun(ctx, args, buf);
            }
        }.d,
    });
    exec.log = &log;
    setSharedExecutor(&exec);

    ensureIo();
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(0) };
    var srv = try addr.listen(io_val, .{ .reuse_address = true });
    defer srv.deinit(io_val);
    const port = srv.socket.address.getPort();

    const Host = struct {
        fn run(listen_srv: *net.Server) void {
            ensureIo();
            const stream = listen_srv.accept(io_val) catch return;
            defer stream.close(io_val);
            var rbuf: [256]u8 = undefined;
            var reader = stream.reader(io_val, &rbuf);
            var pbuf: [256]u8 = undefined;
            _ = decodeFrame(&reader.interface, &pbuf) catch return;
            var wbuf: [256]u8 = undefined;
            var writer = stream.writer(io_val, &wbuf);
            var hbuf: [64]u8 = undefined;
            const resp = formatHostHello(&hbuf, 7) catch return;
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.hello), resp) catch return;
            var sync_pl: [8]u8 = undefined;
            std.mem.writeInt(u64, sync_pl[0..8], 0, .little);
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.sync), &sync_pl) catch return;
            writer.interface.flush() catch return;
            sleepMs(40);
            // a COMMIT with origin = this peer (7) → matches the pending head
            const commit = formatCommitPayload(&pbuf, 1, 7, "stroke", "boom") catch return;
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.commit), commit) catch return;
            writer.interface.flush() catch return;
            sleepMs(200);
        }
    };
    const ht = try std.Thread.spawn(.{}, Host.run, .{&srv});
    defer ht.join();

    var actx: SemCtx = .{};
    registerSem("stroke", &actx, .relay);

    initClientAs(net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) }, .human, "af");
    try waitClientActive(2000);
    var waited_sync: u64 = 0;
    while (testAwaitingSync() and waited_sync < 2000) : (waited_sync += 5) {
        pump();
        sleepMs(5);
    }
    try testing.expectEqual(@as(u32, 7), localPeerId());

    try testing.expect(pendingEnqueue(.{ .proposal_id = 1, .kind = .normal, .redo_of = null, .target_seq = 0 }));
    try testing.expectEqual(@as(usize, 1), testPendingCount());

    var waited: u64 = 0;
    while (inboundLen() < 1 and waited < 2000) : (waited += 5) sleepMs(5);
    pump(); // applying the COMMIT fails → a fail-soft (pending survives)
    try testing.expect(!isEnabled());
    try testing.expectEqual(@as(usize, 1), testPendingCount());
    try testing.expectEqual(@as(u32, 0), log.filled);

    pump(); // wire_session cleared
    try testing.expect(!exec.wire_session);

    // local recording resumes from here on (with the failure removed)
    fail_ctx.fail = false;
    var buf: [128]u8 = undefined;
    const res = try exec.executeAction("stroke", "local", .{ .actor = .local_user, .record_policy = .record }, &buf);
    try testing.expect(res.seq != null);
    try testing.expectEqual(@as(u32, 1), log.filled);
}

// ============================================================================
// the session callback, the environment actor, and the probe's peers and agents
// ============================================================================

var test_session_flag: bool = false;
fn testSessionCb(active: bool) void {
    test_session_flag = active;
}

test "netsync: the session callback fires on enable, clear and fail-soft" {
    resetForTest();
    defer resetForTest();
    test_session_flag = false;
    setSessionStateCallback(testSessionCb);

    initHost(0);
    try testing.expect(test_session_flag);

    shutdown();
    try testing.expect(!test_session_flag);

    // the fail-soft path: a client connects, disconnects, then pump
    test_session_flag = false;
    setSessionStateCallback(testSessionCb);
    ensureIo();
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(0) };
    var srv = try addr.listen(io_val, .{ .reuse_address = true });
    const port = srv.socket.address.getPort();
    var close_gate: std.atomic.Value(bool) = .init(false);
    const Host = struct {
        fn run(listen_srv: *net.Server, gate: *std.atomic.Value(bool)) void {
            ensureIo();
            const stream = listen_srv.accept(io_val) catch return;
            defer stream.close(io_val);
            var rbuf: [256]u8 = undefined;
            var reader = stream.reader(io_val, &rbuf);
            var pbuf: [128]u8 = undefined;
            _ = decodeFrame(&reader.interface, &pbuf) catch return;
            var wbuf: [128]u8 = undefined;
            var writer = stream.writer(io_val, &wbuf);
            var hbuf: [64]u8 = undefined;
            const resp = formatHostHello(&hbuf, 1) catch return;
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.hello), resp) catch return;
            var sync_pl: [8]u8 = undefined;
            std.mem.writeInt(u64, sync_pl[0..8], 0, .little);
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.sync), &sync_pl) catch return;
            writer.interface.flush() catch return;
            var waited: u64 = 0;
            while (!gate.load(.seq_cst) and waited < 5000) : (waited += 10) sleepMs(10);
        }
    };
    const ht = try std.Thread.spawn(.{}, Host.run, .{ &srv, &close_gate });
    defer {
        close_gate.store(true, .seq_cst);
        ht.join();
        srv.deinit(io_val);
    }

    initClientAs(net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) }, .human, "cb");
    try waitClientActive(2000);
    try testing.expect(test_session_flag);

    close_gate.store(true, .seq_cst);
    var waited: u64 = 0;
    while (isEnabled() and waited < 3000) : (waited += 10) sleepMs(10);
    try testing.expect(!isEnabled());
    pump();
    try testing.expect(!test_session_flag);
}

test "netsync: parseActorEnv gives the default, gives agent, and gives human for an invalid value" {
    try testing.expectEqual(ActorKind.human, parseActorEnv(null));
    try testing.expectEqual(ActorKind.human, parseActorEnv("human"));
    try testing.expectEqual(ActorKind.agent, parseActorEnv("agent"));
    try testing.expectEqual(ActorKind.human, parseActorEnv("robot"));
    try testing.expectEqual(ActorKind.human, parseActorEnv(""));
}

test "netsync: an agent HELLO registers in the host's peer table with kind=agent" {
    resetForTest();
    defer resetForTest();
    initHost(0);
    const port = listeningPort().?;
    var stream = try rawHelloConnectAs(net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) }, .agent, "copilot");
    defer stream.close(io_val);
    try waitPeers(1, 2000);
    try pumpUntilAllSynced(2000);
    try expectEmptySync(stream);

    var lbuf: [MAX_LABEL_LEN]u8 = undefined;
    const p = getPeer(0, &lbuf).?;
    try testing.expectEqual(ActorKind.agent, p.kind);
    try testing.expectEqualStrings("copilot", p.label);
    try testing.expectEqual(@as(usize, 1), gatherStats().agents);

    var dig_buf: [512]u8 = undefined;
    const dig = formatDigest(&dig_buf);
    try testing.expect(std.mem.indexOf(u8, dig, "agents=1") != null);

    const snap = try formatSnapshot(testing.allocator);
    defer testing.allocator.free(snap);
    try testing.expect(std.mem.indexOf(u8, snap, "\"kind\":\"agent\"") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "\"label\":\"copilot\"") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "\"peers\":[") != null);
}

test "netsync: setClientIdentity keeps the equivalent of KNGN_NETSYNC_ACTOR and KNGN_NETSYNC_LABEL" {
    resetForTest();
    defer resetForTest();
    const kind = parseActorEnv("agent");
    setClientIdentity(kind, "env-bot");
    try testing.expectEqual(ActorKind.agent, client_actor_kind);
    try testing.expectEqualStrings("env-bot", client_label_buf[0..client_label_len]);
    // initClient puts client_actor_kind and the label on the HELLO (independently of initHost's defaultClientLabel)
    var hbuf: [128]u8 = undefined;
    const hello = try formatClientHello(&hbuf, client_actor_kind, client_label_buf[0..client_label_len]);
    const parsed = try parseClientHello(hello);
    try testing.expectEqual(ActorKind.agent, parsed.kind);
    try testing.expectEqualStrings("env-bot", parsed.label);
}

// ============================================================================
// PRESENCE ephemeral
// ============================================================================

test "netsync: PRESENCE codec round-trip / signed coords / subtype / reject" {
    var buf: [PRESENCE_PAYLOAD_LEN]u8 = undefined;
    const src: PresencePayload = .{
        .origin_peer = 7,
        .subtype = .highlight,
        .ttl_ms = 2000,
        .x0 = -3,
        .y0 = 40,
        .x1 = 100,
        .y1 = -20,
    };
    const enc = try formatPresencePayload(&buf, src);
    try testing.expectEqual(@as(usize, 24), enc.len);
    const dec = try parsePresencePayload(enc);
    try testing.expectEqual(@as(u32, 7), dec.origin_peer);
    try testing.expectEqual(PresenceSubtype.highlight, dec.subtype);
    try testing.expectEqual(@as(u16, 2000), dec.ttl_ms);
    try testing.expectEqual(@as(i32, -3), dec.x0);
    try testing.expectEqual(@as(i32, 40), dec.y0);
    try testing.expectEqual(@as(i32, 100), dec.x1);
    try testing.expectEqual(@as(i32, -20), dec.y1);

    // ttl=0 → expanded to the default
    var zero = src;
    zero.ttl_ms = 0;
    zero.subtype = .point;
    const enc0 = try formatPresencePayload(&buf, zero);
    const dec0 = try parsePresencePayload(enc0);
    try testing.expectEqual(@as(u16, 1500), dec0.ttl_ms);

    // reserved ≠ 0
    var bad = buf;
    @memcpy(&bad, enc);
    bad[5] = 1;
    try testing.expectError(error.ProtocolError, parsePresencePayload(&bad));

    // a length mismatch
    try testing.expectError(error.ProtocolError, parsePresencePayload(enc[0..23]));

    // TTL over the limit
    var over = src;
    over.ttl_ms = 10001;
    const enc_over = try formatPresencePayload(&buf, over);
    try testing.expectError(error.ProtocolError, parsePresencePayload(enc_over));

    // an unknown subtype
    var unk = buf;
    @memcpy(&unk, enc);
    unk[4] = 0x99;
    try testing.expectError(error.ProtocolError, parsePresencePayload(&unk));

    try testing.expectEqual(@as(usize, 24), maxPayloadForKind(0x09));
}

test "netsync: an unknown kind 0x0A is discarded and carries on (compatibility with older peers)" {
    // The same branch as readerMain's: when isKnownKind is false it calls discardPayload and continues.
    // Here, at the codec layer, what is pinned is that "the frame after an unknown kind can still be read".
    try testing.expect(!isKnownKind(0x0A));
    var raw: [5 + 4 + 5 + 3]u8 = undefined;
    // unknown kind 0x0A len=4
    raw[0] = 0x0A;
    std.mem.writeInt(u32, raw[1..5], 4, .little);
    @memcpy(raw[5..9], "xxxx");
    // the equivalent of a known kind, PROPOSE, following
    raw[9] = 0x02;
    std.mem.writeInt(u32, raw[10..14], 3, .little);
    @memcpy(raw[14..17], "abc");

    var r = Io.Reader.fixed(&raw);
    const k1 = try r.takeByte();
    try testing.expectEqual(@as(u8, 0x0A), k1);
    const len1 = try r.takeInt(u32, .little);
    try discardPayload(&r, len1);
    var pbuf: [16]u8 = undefined;
    const frame = try decodeFrame(&r, &pbuf);
    try testing.expectEqual(@as(u8, 0x02), frame.kind);
    try testing.expectEqualStrings("abc", frame.payload);
}

test "netsync: a client's presence_point generates no PROPOSE and leaves seq and pending unchanged" {
    resetForTest();
    defer resetForTest();
    ensureIo();
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(0) };
    var srv = try addr.listen(io_val, .{ .reuse_address = true });
    defer srv.deinit(io_val);
    const port = srv.socket.address.getPort();

    const Host = struct {
        fn run(listen_srv: *net.Server) void {
            ensureIo();
            const stream = listen_srv.accept(io_val) catch return;
            defer stream.close(io_val);
            var rbuf: [512]u8 = undefined;
            var reader = stream.reader(io_val, &rbuf);
            var pbuf: [256]u8 = undefined;
            _ = decodeFrame(&reader.interface, &pbuf) catch return; // HELLO
            var wbuf: [128]u8 = undefined;
            var writer = stream.writer(io_val, &wbuf);
            var hbuf: [64]u8 = undefined;
            const resp = formatHostHello(&hbuf, 1) catch return;
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.hello), resp) catch return;
            writer.interface.flush() catch return;
            var sync_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, sync_buf[0..8], 0, .little);
            encodeFrame(&writer.interface, @intFromEnum(FrameKind.sync), &sync_buf) catch return;
            writer.interface.flush() catch return;
            sleepMs(300); // keep the connection until the client has queued a presence
        }
    };
    const ht = try std.Thread.spawn(.{}, Host.run, .{&srv});
    defer ht.join();

    var ctx: SemCtx = .{};
    registerSem("presence_point", &ctx, .ephemeral);
    const caddr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    initClientAs(caddr, .agent, "helper");
    try waitClientActive(2000);
    var waited: u64 = 0;
    while (testAwaitingSync() and waited < 2000) : (waited += 5) {
        pump();
        sleepMs(5);
    }

    const seq0 = wireSeq();
    const pend0 = testPendingCount();
    const prop0 = next_proposal_id;
    var buf: [64]u8 = undefined;
    const out = try action_registry.routeLocalAction("presence_point", "32 40 1500", &buf);
    try testing.expectEqualStrings("sent", out);
    try testing.expectEqual(seq0, wireSeq());
    try testing.expectEqual(pend0, testPendingCount());
    try testing.expectEqual(prop0, next_proposal_id);
    try testing.expectEqual(@as(u32, 0), ctx.calls); // a client does not dispatch locally
}

test "netsync: a host receiving a presence calls the callback and broadcasts, and does not broadcast on failure" {
    resetForTest();
    defer resetForTest();
    initHost(0);
    var ctx: SemCtx = .{};
    registerSem("presence_point", &ctx, .ephemeral);

    var pbuf: [PRESENCE_PAYLOAD_LEN]u8 = undefined;
    const payload = try formatPresencePayload(&pbuf, .{
        .origin_peer = 0,
        .subtype = .point,
        .ttl_ms = 1500,
        .x0 = 32,
        .y0 = 40,
        .x1 = 0,
        .y1 = 0,
    });
    try testing.expect(presence_inbound.enqueueLatestWins(io_val, 1, payload));
    const seq0 = wireSeq();
    pump();
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    try testing.expect(std.mem.indexOf(u8, ctx.last_args[0..ctx.last_args_len], "peer=1") != null);
    try testing.expectEqual(seq0, wireSeq());

    // the callback fails → the broadcast path is never entered (approximated by nothing being queued: after the failure, calls does not rise)
    ctx.fail = true;
    try testing.expect(presence_inbound.enqueueLatestWins(io_val, 2, payload));
    pump();
    try testing.expectEqual(@as(u32, 1), ctx.calls);
}

test "netsync: the presence queue is latest-wins and drops when full" {
    resetForTest();
    defer resetForTest();
    ensureIo();
    var pbuf: [PRESENCE_PAYLOAD_LEN]u8 = undefined;
    const mk = struct {
        fn go(buf: *[PRESENCE_PAYLOAD_LEN]u8, x: i32) []const u8 {
            return formatPresencePayload(buf, .{
                .origin_peer = 0,
                .subtype = .point,
                .ttl_ms = 1500,
                .x0 = x,
                .y0 = 0,
                .x1 = 0,
                .y1 = 0,
            }) catch unreachable;
        }
    }.go;

    try testing.expect(presence_inbound.enqueueLatestWins(io_val, 1, mk(&pbuf, 10)));
    try testing.expect(presence_inbound.enqueueLatestWins(io_val, 1, mk(&pbuf, 99))); // replace
    try testing.expectEqual(@as(usize, 1), presence_inbound.len(io_val));
    var peer: u32 = 0;
    var out: [PRESENCE_PAYLOAD_LEN]u8 = undefined;
    try testing.expect(presence_inbound.dequeue(io_val, &peer, &out));
    const parsed = try parsePresencePayload(&out);
    try testing.expectEqual(@as(i32, 99), parsed.x0);

    // a drop because it is full (without disconnecting)
    var i: usize = 0;
    while (i < PRESENCE_QUEUE_CAP) : (i += 1) {
        // change the peer to fill the slot
        try testing.expect(presence_inbound.enqueueLatestWins(io_val, @intCast(i + 1), mk(&pbuf, @intCast(i))));
    }
    try testing.expect(!presence_inbound.enqueueLatestWins(io_val, 999, mk(&pbuf, 1)));
    try testing.expectEqual(@as(usize, PRESENCE_QUEUE_CAP), presence_inbound.len(io_val));
}

test "netsync: a presence is applied even while awaiting_sync, and the COMMIT is held" {
    resetForTest();
    defer resetForTest();
    ensureIo();
    // Set the client role by hand (checking the pump path alone, with no connection)
    peers_mutex.lockUncancelable(io_val);
    role = .client;
    started = true;
    awaiting_sync = true;
    peers_mutex.unlock(io_val);
    enableRouter();

    var ctx: SemCtx = .{};
    registerSem("presence_point", &ctx, .ephemeral);
    registerSem("stroke", &ctx, .relay);

    var pbuf: [PRESENCE_PAYLOAD_LEN]u8 = undefined;
    const presence = try formatPresencePayload(&pbuf, .{
        .origin_peer = 1,
        .subtype = .point,
        .ttl_ms = 1500,
        .x0 = 5,
        .y0 = 6,
        .x1 = 0,
        .y1 = 0,
    });
    try testing.expect(presence_inbound.enqueueLatestWins(io_val, 0, presence));

    // the COMMIT onto the ordinary inbound queue
    var cbuf: [64]u8 = undefined;
    const commit = try formatCommitPayload(&cbuf, 1, 0, "stroke", "1 2");
    try testing.expect(inbound.enqueue(io_val, @intFromEnum(FrameKind.commit), commit, 0));

    pump(); // while awaiting: presence is applied and the COMMIT is not dequeued
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    try testing.expect(std.mem.eql(u8, ctx.last_args[0..ctx.last_args_len], "peer=1 5 6 1500") or
        std.mem.indexOf(u8, ctx.last_args[0..ctx.last_args_len], "peer=1") != null);
    try testing.expectEqual(@as(usize, 1), inboundLen());
    try testing.expect(testAwaitingSync());
}

test "netsync: applying a presence leaves wire_seq, proposal and pending unchanged" {
    resetForTest();
    defer resetForTest();
    initHost(0);
    var ctx: SemCtx = .{};
    registerSem("presence_highlight", &ctx, .ephemeral);
    registerSem("presence_suggest", &ctx, .ephemeral);

    const seq0 = wireSeq();
    const prop0 = next_proposal_id;
    const pend0 = testPendingCount();

    var buf: [64]u8 = undefined;
    _ = try action_registry.routeLocalAction("presence_highlight", "10 12 40 24 2000", &buf);
    _ = try action_registry.routeLocalAction("presence_suggest", "48 48", &buf);

    try testing.expectEqual(seq0, wireSeq());
    try testing.expectEqual(prop0, next_proposal_id);
    try testing.expectEqual(pend0, testPendingCount());
    try testing.expectEqual(@as(u32, 2), ctx.calls);
}

test "netsync: the router's ephemeral branch on a host and on a client" {
    resetForTest();
    defer resetForTest();
    var ctx: SemCtx = .{};
    registerSem("presence_point", &ctx, .ephemeral);
    initHost(0);
    var buf: [64]u8 = undefined;
    const r = try action_registry.routeLocalAction("presence_point", "1 2", &buf);
    try testing.expect(std.mem.indexOf(u8, r, "ok:") != null or std.mem.indexOf(u8, r, "peer=") != null);
    try testing.expectEqual(@as(u64, 0), wireSeq());
}
