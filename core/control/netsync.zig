//! netsync transport + PROPOSE/COMMIT/REJECT relay（TASK-62.3.1 / 62.3.2）。
//!
//! 62.3.1: 持続 TCP・HELLO・フレーム codec・キュー。
//! 62.3.2: NetworkPolicy router・commitAndBroadcast / proposeToHost・pump 内 semantic 適用。
//! StateSync / revert undo / command log 統合（remote_commit）は 62.3.3〜62.3.5。
//! 本モジュールは std のみ（ADR-007 core 層。harness/libs 非依存）。action_registry / command は
//! 相対 import（harness 経由で同一インスタンスを共有する）。
//!
//! ## ホットパス宣言
//! 全コードは「イベント時のみ」（接続確立・フレーム受信・HELLO・PROPOSE/COMMIT 適用）。
//! `pump()` は毎フレーム呼ばれるが、処理量は inbound pending 件数に比例（空なら即 return）。
//! フレーム毎の全画素ループ / RT（毎サンプル）には触れない。reader/writer/acceptor は
//! ブロッキング socket I/O 専用で app 状態に触れない（適用は main thread の pump のみ）。
//!
//! ## remote 適用の暫定例外（62.3.2）
//! wire seq を `ExecuteSource.remote_commit` で流し込まない（client local_only の seq 消費と
//! StaleRemoteSeq 衝突のため）。共有 executor 経由 `source=.local` + `record_policy=.no_record`。
//! 62.3.5 で本則へ移行。executor 未設定時は `action_registry.dispatch` fallback。

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
    _,
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

pub const Role = enum { disabled, host, client };
const SlotState = enum { empty, hello_pending, active, closing };

pub const ProtocolError = error{
    PayloadTooLarge,
    ProtocolError,
    EndOfStream,
};

/// kind 別の payload 上限（超過は protocol error 切断）。
pub fn maxPayloadForKind(kind: u8) usize {
    return if (kind == @intFromEnum(FrameKind.sync)) MAX_SYNC_BYTES else MAX_ACTION_FRAME_BYTES;
}

pub fn isKnownKind(kind: u8) bool {
    return kind >= 0x01 and kind <= 0x08;
}

/// フレームを Writer へ encode（kind + len LE + payload）。
pub fn encodeFrame(w: *Io.Writer, kind: u8, payload: []const u8) Io.Writer.Error!void {
    try w.writeByte(kind);
    try w.writeInt(u32, @intCast(payload.len), .little);
    try w.writeAll(payload);
}

/// ヘッダを読み、len が上限内なら payload を `buf` へ読む。超過は `error.PayloadTooLarge`。
/// 戻り値の payload は `buf[0..len]`。
pub fn decodeFrame(r: *Io.Reader, buf: []u8) (ProtocolError || Io.Reader.Error)!Frame {
    const kind = try r.takeByte();
    const len = try r.takeInt(u32, .little);
    const max = maxPayloadForKind(kind);
    if (len > max) return error.PayloadTooLarge;
    if (len > buf.len) return error.PayloadTooLarge;
    if (len > 0) try r.readSliceAll(buf[0..len]);
    return .{ .kind = kind, .payload = buf[0..len] };
}

/// payload を streaming 読み捨て（固定 4096B チャンク。SYNC の 16MiB を alloc しない）。
pub fn discardPayload(r: *Io.Reader, len: u32) (Io.Reader.Error)!void {
    var remaining: u32 = len;
    var chunk: [MAX_ACTION_FRAME_BYTES]u8 = undefined;
    while (remaining > 0) {
        const n: u32 = @min(remaining, @as(u32, @intCast(chunk.len)));
        try r.readSliceAll(chunk[0..n]);
        remaining -= n;
    }
}

/// HELLO payload 検証用（client→host）。成功時 kind/label を返す。label は payload 内 slice。
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
        if (c < 0x20) return error.ProtocolError; // ASCII 制御文字
    }
    return .{ .kind = kind, .label = label };
}

/// HELLO payload 検証用（host→client）。成功時 peer_id を返す。
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

/// `"<name> <args>"` または `"<name>"` を分割（name=最初の空白まで、args=残り）。
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

// ============================================================================
// Queues
// ============================================================================

/// 内部 inbound マーカー（wire には出ない）。ClientJoined = peer_id + generation。
const INTERNAL_CLIENT_JOINED: u8 = 0xF0;

const QueueSlot = struct {
    kind: u8 = 0,
    len: u32 = 0,
    /// 受信元 peer_id（host の PROPOSE 処理・REJECT 返送用。client 受信は 0=host）。
    peer_id: u32 = 0,
    data: [MAX_ACTION_FRAME_BYTES]u8 = undefined,
};

/// outbound 単一 FIFO ring のエントリ（inline ≤4096 / big = heap 所有）。
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

    /// SYNC 等の big-entry。成功時は `owned` の所有権を queue が取る。失敗時は呼び出し元が解放。
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

    /// writer 用。closed かつ空なら null。エントリ所有権を呼び出し元へ移転。
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
};

// ============================================================================
// Connection slot
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
    /// SYNC 送出済み（broadcast 対象）。ClientJoined 処理後に true。
    synced: bool = false,
    /// export 成功で true。空 SYNC（未登録）は false（62.3.5 revert 制限用）。
    snapshot_valid: bool = false,
    join_snapshot_seq: u64 = 0,
    /// slot 再利用検知用。empty へ戻すたびに increment。
    generation: u32 = 0,
    reader_thread: ?std.Thread = null,
    writer_thread: ?std.Thread = null,
    outbound: OutboundQueue = .{},
    /// host slots 配列内 index。client は 0。
    slot_index: usize = 0,
    is_client_conn: bool = false,
};

/// join 時 state 同期アダプタ（単一スロット）。
/// `export_fn` は **0 byte を返してはならない**（空は「snapshot なし」予約マーカー。未登録時のみ空 SYNC）。
pub const StateSync = struct {
    ctx: *anyopaque,
    export_fn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8,
    import_fn: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void,
};

// ============================================================================
// Module state
// ============================================================================
//
// ## 同期規約（peers_mutex）
// 次のフィールドの読み書きはすべて `peers_mutex` 下で行う（イベント時のみの経路）:
//   role / started / local_peer_id / next_peer_id / router_clear_pending /
//   slots[*].state および slot の peer メタ（peer_id/kind/label/hello_done/socket_open）/
//   client_slot の同種フィールド
// `stop_flag` のみ atomic。`have_server` / acceptor_thread は main（init/shutdown）専有。
// wire_seq / next_proposal_id / last_rejected_* / last_applied_seq / shared_executor は main thread 専有
// （pump / router / setSharedExecutor。reader は触らない）。
// outbound キューは独自 mutex を持ち、ロック順序は **peers_mutex → outbound.mutex**（逆順禁止）。

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
var next_peer_id: u32 = 1; // 0 = host 予約

var client_slot: ConnSlot = .{};
var local_peer_id: u32 = 0; // client が host HELLO で受け取る

var inbound: InboundQueue = .{};

var client_actor_kind: ActorKind = .human;
/// 既定 label。`undefined` + len だけ先に立てると NUL が HELLO に載り host が切断する（E2E で確認済み）。
const default_client_label = "client";
var client_label_buf: [MAX_LABEL_LEN]u8 = blk: {
    var b = [_]u8{0} ** MAX_LABEL_LEN;
    @memcpy(b[0..default_client_label.len], default_client_label);
    break :blk b;
};
var client_label_len: usize = default_client_label.len;

/// client fail-soft（reader 起点）から main の pump へ router 解除を依頼するフラグ。
var router_clear_pending: bool = false;

/// host の wire COMMIT seq（単調増加。main thread 専有）。
var wire_seq: u64 = 0;
/// client: 最後に適用した COMMIT の seq（main thread 専有。digest last_seq の client 側）。
var last_applied_seq: u64 = 0;
/// client の proposal_id（単調増加。main thread 専有）。
var next_proposal_id: u32 = 0;

var shared_executor: ?*command.Executor = null;

var last_rejected_proposal: u32 = 0;
var last_reject_reason_buf: [256]u8 = undefined;
var last_reject_reason_len: usize = 0;

var state_sync: ?StateSync = null;
/// client: SYNC import 完了まで true。この間 pump は inbound dequeue ループに入らない。
var awaiting_sync: bool = false;
/// client reader が積む SYNC payload（seq+state）。peers_mutex 下で置換・解放。
var pending_sync: ?[]u8 = null;

/// 観測用スナップショット（TASK-62.3.4）。
/// `gatherStats` / probe digest・snapshot は harness 設計上 **main thread（pollGate 内）でのみ**呼ぶ。
pub const NetsyncStats = struct {
    role: Role = .disabled,
    peers: usize = 0,
    peer_id: u32 = 0,
    last_seq: u64 = 0,
    pending: usize = 0,
    awaiting_sync: bool = false,
    last_reject: u32 = 0,
};

/// reader 共有フィールドを 1 回の `peers_mutex` 保持で一括取得し、main thread 専有値を足す。
/// **main thread 専用**（probe = pollGate 内前提）。
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
                if (s.state == .active) st.peers += 1;
            }
        } else if (role == .client and client_slot.state == .active) {
            st.peers = 1;
        }
    }
    peers_mutex.unlock(io_val);

    if (!on) return st;

    // main thread 専有（lock 不要）
    st.last_seq = if (st.role == .host) wire_seq else last_applied_seq;
    st.last_reject = last_rejected_proposal;
    return st;
}

const reject_reason_token_max = 64;

/// ASCII whitespace（space/tab/CR/LF）と制御文字を `_` に置換し、最大 64B に切り詰める。
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

/// digest 1 行 payload（probe 名は harness が付与。`role=... peers=...`）。**main thread 専用**。
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

    return std.fmt.bufPrint(buf, "role={s} peers={d} peer_id={d} last_seq={d} pending={d} awaiting_sync={d} last_reject={s} reject_reason={s}", .{
        roleDigestName(st.role),
        st.peers,
        st.peer_id,
        st.last_seq,
        st.pending,
        @as(u8, if (st.awaiting_sync) 1 else 0),
        reject_tok,
        reason_tok,
    }) catch buf[0..0];
}

/// snapshot JSON 1 オブジェクト。command log 要約は 62.3.5 まで未提供（no_record 暫定例外のため）。
/// **main thread 専用**。
pub fn formatSnapshot(allocator: std.mem.Allocator) ![]u8 {
    const st = gatherStats();
    var reason_buf: [reject_reason_token_max]u8 = undefined;
    if (st.last_reject == 0) {
        return std.fmt.allocPrint(allocator, "{{\"role\":\"{s}\",\"peers\":{d},\"peer_id\":{d},\"last_seq\":{d},\"pending\":{d},\"awaiting_sync\":{s},\"last_reject\":null,\"reject_reason\":null}}", .{
            roleDigestName(st.role),
            st.peers,
            st.peer_id,
            st.last_seq,
            st.pending,
            if (st.awaiting_sync) "true" else "false",
        });
    }
    const reason_tok = sanitizeRejectReasonToken(&reason_buf, lastRejectReason());
    // JSON 文字列用に " \ を除外（sanitize 後も残りうる）
    var json_reason: [reject_reason_token_max]u8 = undefined;
    const rn = @min(reason_tok.len, json_reason.len);
    for (reason_tok[0..rn], 0..) |c, i| {
        json_reason[i] = if (c == '"' or c == '\\') '_' else c;
    }
    return std.fmt.allocPrint(allocator, "{{\"role\":\"{s}\",\"peers\":{d},\"peer_id\":{d},\"last_seq\":{d},\"pending\":{d},\"awaiting_sync\":{s},\"last_reject\":{d},\"reject_reason\":\"{s}\"}}", .{
        roleDigestName(st.role),
        st.peers,
        st.peer_id,
        st.last_seq,
        st.pending,
        if (st.awaiting_sync) "true" else "false",
        st.last_reject,
        json_reason[0..rn],
    });
}

/// harness custom probe 用 digest（ctx 未使用）。
pub fn probeDigest(_: *anyopaque, buf: []u8) []const u8 {
    return formatDigest(buf);
}

/// harness custom probe 用 snapshot（ctx 未使用）。
pub fn probeSnapshot(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    return formatSnapshot(allocator);
}

/// StateSync を登録する（netsync 無効時も保存のみ・常に呼んでよい）。
/// export_fn は 0 byte を返してはならない（返した場合は export 失敗扱い）。
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

/// platform.setCommandExecutor から転送。remote COMMIT / host PROPOSE 適用に使う（main thread）。
pub fn setSharedExecutor(exec: ?*command.Executor) void {
    shared_executor = exec;
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

fn enableRouter() void {
    action_registry.setRouter(netsyncRouter);
    action_registry.setEnabled(true);
}

fn clearRouterMain() void {
    action_registry.setRouter(null);
    if (io_inited) {
        peers_mutex.lockUncancelable(io_val);
        router_clear_pending = false;
        peers_mutex.unlock(io_val);
    } else {
        router_clear_pending = false;
    }
}

fn requestRouterClear() void {
    // peers_mutex 保持下で呼ぶこと（cleanup / failSoftLocked）。
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
    } else if (role == .client and client_slot.state == .active) {
        n = 1;
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
    } else if (role == .client and client_slot.state == .active) {
        if (i == 0) {
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
    // label が client_label_buf 自身を指す場合（initClient 経由）はコピー不要。
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
    const host_req = getEnv("VP_NETSYNC_HOST") != null;
    const connect = getEnv("VP_NETSYNC_CONNECT");
    if (host_req and connect != null) {
        std.debug.print("[netsync] VP_NETSYNC_HOST と VP_NETSYNC_CONNECT は同時指定不可。無効化します。\n", .{});
        return;
    }
    if (host_req) {
        const port_s = getEnv("VP_NETSYNC_PORT") orelse {
            std.debug.print("[netsync] VP_NETSYNC_HOST=1 には VP_NETSYNC_PORT が必要です。無効化します。\n", .{});
            return;
        };
        const port = std.fmt.parseInt(u16, port_s, 10) catch {
            std.debug.print("[netsync] VP_NETSYNC_PORT が不正です。無効化します。\n", .{});
            return;
        };
        initHost(port);
        return;
    }
    if (connect) |c| {
        const addr = parseConnectAddr(c) orelse {
            std.debug.print("[netsync] VP_NETSYNC_CONNECT が不正です（ip:port）: {s}\n", .{c});
            return;
        };
        initClient(addr);
    }
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

    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    server = addr.listen(io_val, .{ .reuse_address = true }) catch |err| {
        std.debug.print("[netsync] host listen 失敗: {s}\n", .{@errorName(err)});
        return;
    };
    have_server = true;

    peers_mutex.lockUncancelable(io_val);
    next_peer_id = 1;
    role = .host;
    started = true;
    peers_mutex.unlock(io_val);

    acceptor_thread = std.Thread.spawn(.{}, acceptorMain, .{}) catch |err| {
        std.debug.print("[netsync] acceptor spawn 失敗: {s}\n", .{@errorName(err)});
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
    std.debug.print("[netsync] host 有効: 127.0.0.1:{d}\n", .{server.socket.address.getPort()});
}

pub fn initClient(addr: net.IpAddress) void {
    // initFromEnv→initClient は initHost と違い defaultClientLabel を呼ばない。
    // 宣言時初期化が正だが、空なら既定を入れ直す（client 経路の label 常時有効を保証）。
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

    // HELLO encode にも内部保存と同じ切り詰め済み label を使う（201B 以上を素通しすると
    // host 側の label 上限で protocol error 切断になるため、API 境界で clamp する）。
    const label_clamped = client_label_buf[0..client_label_len];

    const stream = addr.connect(io_val, .{ .mode = .stream }) catch |err| {
        std.debug.print("[netsync] client 接続失敗: {s}（netsync 無効のまま起動継続）\n", .{@errorName(err)});
        return; // fail-soft
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
    peers_mutex.unlock(io_val);

    client_slot.writer_thread = std.Thread.spawn(.{}, writerMain, .{&client_slot}) catch {
        std.debug.print("[netsync] client writer spawn 失敗\n", .{});
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
        std.debug.print("[netsync] client reader spawn 失敗\n", .{});
        // writer join 前に close しない（不変条件: close は writer join 後に 1 回）。
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

    // HELLO 送出前に awaiting_sync を立てる（reader が先行して置いた pending_sync を
    // 後から free して永久停止する race を防ぐ）。
    next_proposal_id = 0;
    last_applied_seq = 0;
    peers_mutex.lockUncancelable(io_val);
    awaiting_sync = true;
    freePendingSyncLocked();
    peers_mutex.unlock(io_val);

    // client HELLO を outbound へ
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
    std.debug.print("[netsync] client 接続中\n", .{});
}

/// inbound を drain し PROPOSE/COMMIT/REJECT/ClientJoined を適用する（main thread。毎フレーム可）。
/// `router_clear_pending` の処理は `isEnabled` 早期 return より前（fail-soft 後も解除する）。
/// awaiting_sync 中は pending_sync import のみ試し、inbound dequeue ループには入らない。
pub fn pump() void {
    if (!io_inited) return;

    // fail-soft 後の router 解除（main thread のみ setRouter）。
    peers_mutex.lockUncancelable(io_val);
    const clear = router_clear_pending;
    if (clear) router_clear_pending = false;
    peers_mutex.unlock(io_val);
    if (clear) {
        action_registry.setRouter(null);
    }

    if (!isEnabled()) return;

    // awaiting 中に SYNC を適用しても、同 pump では COMMIT を dequeue しない（次 pump で再開）。
    peers_mutex.lockUncancelable(io_val);
    const was_awaiting = awaiting_sync;
    peers_mutex.unlock(io_val);

    tryApplyPendingSync();
    if (was_awaiting) return;

    var kind: u8 = 0;
    var peer: u32 = 0;
    var buf: [MAX_ACTION_FRAME_BYTES]u8 = undefined;
    while (inbound.dequeue(io_val, &kind, &peer, &buf)) |n| {
        const payload = buf[0..n];
        if (kind == INTERNAL_CLIENT_JOINED) {
            handleClientJoined(payload);
        } else {
            handleInboundFrame(kind, peer, payload);
        }
    }
}

/// テスト用: inbound を 1 件 dequeue（awaiting_sync 中は null）。
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
        .commit => handleCommit(payload),
        .reject => handleReject(payload),
        .sync => {
            // host が SYNC を受けるのは仕様外（reader 側でも切断するが防御）。
            std.debug.print("[netsync] unexpected SYNC on host path — ignore\n", .{});
        },
        else => {},
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
                std.debug.print("[netsync] StateSync export 失敗: {s} — client 切断\n", .{@errorName(err)});
                requestCloseSlotIfGeneration(slot, peer_id, generation);
                return;
            };
            if (state.len == 0) {
                gpa.free(state);
                std.debug.print("[netsync] StateSync export が 0 byte — client 切断\n", .{});
                requestCloseSlotIfGeneration(slot, peer_id, generation);
                return;
            }
            snapshot_valid = true;
            const payload_bytes = buildSyncPayload(seq, state) catch {
                gpa.free(state);
                std.debug.print("[netsync] SYNC payload 過大 — client 切断\n", .{});
                requestCloseSlotIfGeneration(slot, peer_id, generation);
                return;
            };
            gpa.free(state);
            break :blk payload_bytes;
        } else {
            // 未登録: 空 SYNC（seq のみ）+ snapshot_valid=false
            break :blk buildSyncPayload(seq, &[_]u8{}) catch {
                requestCloseSlotIfGeneration(slot, peer_id, generation);
                return;
            };
        }
    };

    peers_mutex.lockUncancelable(io_val);
    // 再検証（export 中に切断された可能性）
    if (slot.state != .active or slot.peer_id != peer_id or slot.generation != generation) {
        peers_mutex.unlock(io_val);
        gpa.free(sync_bytes);
        return;
    }
    if (!slot.outbound.enqueueBig(io_val, @intFromEnum(FrameKind.sync), sync_bytes)) {
        peers_mutex.unlock(io_val);
        gpa.free(sync_bytes);
        std.debug.print("[netsync] SYNC enqueue 失敗 — client 切断\n", .{});
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
        std.debug.print("[netsync] SYNC parse 失敗 — fail-soft\n", .{});
        failSoftDisableClient();
        return;
    };
    if (parsed.seq > wire_seq) wire_seq = parsed.seq;

    if (parsed.state.len == 0) {
        // 空 SYNC: import せずゲート解除
        peers_mutex.lockUncancelable(io_val);
        awaiting_sync = false;
        peers_mutex.unlock(io_val);
        return;
    }

    const ss = state_sync orelse {
        // import 未登録だが非空 SYNC → 適用不能
        std.debug.print("[netsync] SYNC 受信したが StateSync 未登録 — fail-soft\n", .{});
        failSoftDisableClient();
        return;
    };
    ss.import_fn(ss.ctx, parsed.state) catch |err| {
        std.debug.print("[netsync] StateSync import 失敗: {s} — fail-soft（保留 COMMIT 不適用）\n", .{@errorName(err)});
        failSoftDisableClient();
        return;
    };
    peers_mutex.lockUncancelable(io_val);
    awaiting_sync = false;
    peers_mutex.unlock(io_val);
}

fn applyRemoteNoRecord(name: []const u8, args: []const u8, origin_peer: u32, buf: []u8) anyerror![]const u8 {
    if (shared_executor) |exec| {
        const res = try exec.executeAction(name, args, .{
            .actor = .{ .peer = origin_peer },
            .source = .local,
            .record_policy = .no_record,
        }, buf);
        return res.output;
    }
    return action_registry.dispatch(name, args, buf);
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

fn nextWireSeq() u64 {
    wire_seq += 1;
    return wire_seq;
}

fn broadcastCommit(seq: u64, origin_peer: u32, name: []const u8, args: []const u8) void {
    var cbuf: [MAX_ACTION_FRAME_BYTES]u8 = undefined;
    const payload = formatCommitPayload(&cbuf, seq, origin_peer, name, args) catch {
        std.debug.print("[netsync] COMMIT payload 構築失敗\n", .{});
        return;
    };
    broadcast(@intFromEnum(FrameKind.commit), payload);
}

fn sendReject(peer_id: u32, proposal_id: u32, reason: []const u8) void {
    var rbuf: [MAX_ACTION_FRAME_BYTES]u8 = undefined;
    const payload = formatRejectPayload(&rbuf, proposal_id, reason) catch return;
    _ = enqueueToPeer(peer_id, @intFromEnum(FrameKind.reject), payload);
}

/// host ローカル .relay: dispatch → 成功時 wire seq 採番 → 全 client へ COMMIT(origin=0)。
pub fn commitAndBroadcast(name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
    const out = try action_registry.dispatch(name, args, buf);
    const seq = nextWireSeq();
    broadcastCommit(seq, 0, name, args);
    return out;
}

/// client ローカル .relay: proposal_id 採番 + PROPOSE 送信。ローカル適用なし。
pub fn proposeToHost(name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
    next_proposal_id += 1;
    const id = next_proposal_id;
    var pbuf: [MAX_ACTION_FRAME_BYTES]u8 = undefined;
    const payload = formatProposePayload(&pbuf, id, name, args) catch return error.PayloadTooLarge;
    if (!clientSend(@intFromEnum(FrameKind.propose), payload)) {
        return error.ProposeSendFailed;
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
    var abuf: [MAX_ACTION_FRAME_BYTES]u8 = undefined;
    _ = applyRemoteNoRecord(parsed.name, parsed.args, from_peer, &abuf) catch |err| {
        var reason_buf: [64]u8 = undefined;
        const reason = std.fmt.bufPrint(&reason_buf, "{s}", .{@errorName(err)}) catch "apply failed";
        sendReject(from_peer, parsed.proposal_id, reason);
        return;
    };
    const seq = nextWireSeq();
    broadcastCommit(seq, from_peer, parsed.name, parsed.args);
}

fn handleCommit(payload: []const u8) void {
    if (!isClient()) return;
    const parsed = parseCommitPayload(payload) catch {
        std.debug.print("[netsync] COMMIT parse 失敗\n", .{});
        return;
    };
    // wire seq は記録しない（暫定例外）。単調性の観測用にだけ進める。
    if (parsed.seq > wire_seq) wire_seq = parsed.seq;
    var abuf: [MAX_ACTION_FRAME_BYTES]u8 = undefined;
    _ = applyRemoteNoRecord(parsed.name, parsed.args, parsed.origin_peer, &abuf) catch |err| {
        std.debug.print("[netsync] COMMIT 適用失敗: {s}\n", .{@errorName(err)});
        return;
    };
    last_applied_seq = parsed.seq;
}

fn handleReject(payload: []const u8) void {
    if (!isClient()) return;
    const parsed = parseRejectPayload(payload) catch {
        std.debug.print("[netsync] REJECT parse 失敗\n", .{});
        return;
    };
    last_rejected_proposal = parsed.proposal_id;
    const n = @min(parsed.reason.len, last_reject_reason_buf.len);
    if (n > 0) @memcpy(last_reject_reason_buf[0..n], parsed.reason[0..n]);
    last_reject_reason_len = n;
    std.debug.print("[netsync] REJECT proposal={d} reason={s}\n", .{ parsed.proposal_id, lastRejectReason() });
}

/// host/client 対称の NetworkPolicy 分岐（親 plan §1.3）。
/// **main thread のみ**（routeLocalAction 経由）。role=.disabled なら dispatch fallback。
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
            // TODO(62.3.5): commitRevertOwnLatest / commitReapplyOwnReverted に差し替え
            .undo_own, .redo_own => error.RejectedWhileSynced,
        },
        .client => switch (act.network_policy) {
            .relay => proposeToHost(name, args, buf),
            .local_only => action_registry.dispatch(name, args, buf),
            .reject_when_synced => error.RejectedWhileSynced,
            // TODO(62.3.5): proposeRevertOwnLatest / reproposeOwnReverted に差し替え
            .undo_own, .redo_own => error.RejectedWhileSynced,
        },
        .disabled => action_registry.dispatch(name, args, buf),
    };
}

/// active かつ synced な全接続の outbound へ fan-out。
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

/// client 役の outbound へ 1 フレーム積む（テスト・将来 PROPOSE 送出の最小口）。
/// 満杯時は fail-soft で netsync を無効化する。
/// state 確認と enqueue は同一 `peers_mutex` 区間（TOCTOU 防止）。
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

    // listen socket を先に close すると blocking accept が BADF panic になる。
    // ダミー connect で accept を起こし、acceptor join 後にだけ listen を閉じる。
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
    peers_mutex.lockUncancelable(io_val);
    role = .disabled;
    started = false;
    local_peer_id = 0;
    next_peer_id = 1;
    router_clear_pending = false;
    awaiting_sync = false;
    freePendingSyncLocked();
    peers_mutex.unlock(io_val);
    // main thread のみ setRouter(null)
    action_registry.setRouter(null);
    wire_seq = 0;
    last_applied_seq = 0;
    next_proposal_id = 0;
    last_rejected_proposal = 0;
    last_reject_reason_len = 0;
}

fn requestCloseSlot(s: *ConnSlot) void {
    peers_mutex.lockUncancelable(io_val);
    defer peers_mutex.unlock(io_val);
    requestCloseSlotLocked(s);
}

/// export 中などに slot が再利用された場合、新しい接続を誤って閉じない。
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
    // ## fd close 不変条件
    // fd を使いうる全スレッド（特に writer）を join するまで stream.close してはならない。
    // 他スレッドを起こす手段は outbound.close（condvar）と stream.shutdown(.both) のみ。
    // close は writer join 後に、ちょうど 1 回・peers_mutex 下で socket_open を見て実行する
    //（cleanupAfterReader / spawn 失敗経路 / joinSlot）。他スレッドから close すると
    // blocking 中の send/recv が EBADF → Zig std の unreachable panic になる。
    if (s.socket_open) {
        s.stream.shutdown(io_val, .both) catch {};
    }
}

fn joinSlot(s: *ConnSlot) void {
    // Thread handle の join は mutex 外（cleanup と競合しうるが、handle が残っていれば join）。
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
    // reader cleanup が既に close 済みなら no-op。未 close ならここで唯一の所有者として close。
    if (s.socket_open) {
        s.stream.close(io_val);
        s.socket_open = false;
    }
    s.outbound.reset(io_val);
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

/// client を fail-soft 無効化（peers_mutex を取得する）。
fn failSoftDisableClient() void {
    std.debug.print("[netsync] client を fail-soft 無効化します\n", .{});
    peers_mutex.lockUncancelable(io_val);
    defer peers_mutex.unlock(io_val);
    failSoftDisableClientLocked();
}

/// `peers_mutex` 保持下で client を無効化。接続が残っていれば閉じる。
fn failSoftDisableClientLocked() void {
    if (client_slot.state != .empty and client_slot.state != .closing) {
        requestCloseSlotLocked(&client_slot);
    }
    role = .disabled;
    started = false;
    local_peer_id = 0;
    awaiting_sync = false;
    freePendingSyncLocked();
    requestRouterClear();
}

// ============================================================================
// Threads
// ============================================================================

fn acceptorMain() void {
    while (!stop_flag.load(.seq_cst)) {
        const stream = server.accept(io_val) catch |err| {
            if (stop_flag.load(.seq_cst)) break;
            std.debug.print("[netsync] accept 失敗: {s}\n", .{@errorName(err)});
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
                    // generation は前回 empty 化時に increment 済み。再利用時は保持。
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
            std.debug.print("[netsync] peer スロット満杯（MAX_PEERS={d}）。接続を切断します\n", .{MAX_PEERS});
            stream.close(io_val);
            continue;
        }
        const slot = slot_opt.?;

        slot.writer_thread = std.Thread.spawn(.{}, writerMain, .{slot}) catch {
            std.debug.print("[netsync] writer spawn 失敗 — スロット解放\n", .{});
            peers_mutex.lockUncancelable(io_val);
            stream.close(io_val);
            slot.state = .empty;
            peers_mutex.unlock(io_val);
            continue;
        };
        slot.reader_thread = std.Thread.spawn(.{}, readerMain, .{slot}) catch {
            std.debug.print("[netsync] reader spawn 失敗 — スロット解放\n", .{});
            // writer join 前に close しない（不変条件: close は writer join 後に 1 回）。
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
    while (true) {
        if (slot.outbound.dequeueWait(io_val, &entry) == null) break;
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
        entry.free(); // 送出後（成功・失敗とも）big を解放
        if (!send_ok) {
            requestCloseSlot(slot);
            break;
        }
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

        // HELLO 完了前は HELLO 以外をすべて protocol error 切断（SYNC/未知の読み捨て継続より先）。
        if (!slot.hello_done and kind != @intFromEnum(FrameKind.hello)) {
            break;
        }

        // SYNC: client は heap へ読んで pending。host 受信は protocol error。
        if (kind == @intFromEnum(FrameKind.sync)) {
            if (!slot.is_client_conn) {
                std.debug.print("[netsync] host が SYNC を受信 — protocol error 切断\n", .{});
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
            std.debug.print("[netsync] 未知 frame kind=0x{x:0>2} len={d} — 読み捨て継続\n", .{ kind, len });
            discardPayload(&reader.interface, len) catch break;
            continue;
        }

        if (len > payload_buf.len) break;
        if (len > 0) reader.interface.readSliceAll(payload_buf[0..len]) catch break;
        const payload = payload_buf[0..len];

        if (!slot.hello_done) {
            handleHello(slot, payload) catch {
                if (!slot.is_client_conn) {
                    std.debug.print("[netsync] HELLO protocol error — 切断\n", .{});
                }
                break;
            };
            continue;
        }

        if (kind == @intFromEnum(FrameKind.hello)) break; // duplicate HELLO

        if (!inbound.enqueue(io_val, kind, payload, slot.peer_id)) {
            std.debug.print("[netsync] inbound 満杯 — 接続を切断します\n", .{});
            break;
        }
    }

    if (!slot.hello_done and slot.is_client_conn) {
        std.debug.print("[netsync] HELLO 握手失敗（接続が閉じられました）\n", .{});
    }
}

/// reader 終了時: writer を起こして join し、その後にだけ fd を close してスロットを empty へ戻す。
/// 順序: outbound.close → shutdown → writer join → stream.close（1 回）→ slot reset。
fn cleanupAfterReader(slot: *ConnSlot) void {
    const was_client = slot.is_client_conn;

    peers_mutex.lockUncancelable(io_val);
    if (slot.state != .empty and slot.state != .closing) {
        slot.state = .closing;
        slot.outbound.close(io_val);
    } else {
        slot.outbound.close(io_val);
    }
    // writer を起こすだけ。close は join 後（下）。
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
    slot.state = .empty;
    slot.hello_done = false;
    slot.synced = false;
    slot.snapshot_valid = false;
    slot.join_snapshot_seq = 0;
    slot.generation +%= 1;
    slot.peer_id = 0;
    slot.label_len = 0;
    slot.reader_thread = null;
    // client 切断後は同 mutex 下で netsync を fail-soft 無効化。router 解除は pump へ委譲。
    if (was_client) {
        role = .disabled;
        started = false;
        local_peer_id = 0;
        awaiting_sync = false;
        freePendingSyncLocked();
        requestRouterClear();
    }
    peers_mutex.unlock(io_val);

    if (was_client) {
        std.debug.print("[netsync] client を fail-soft 無効化します\n", .{});
    }
}

fn handleHello(slot: *ConnSlot, payload: []const u8) ProtocolError!void {
    if (slot.is_client_conn) {
        // host→client 応答
        const pid = try parseHostHello(payload);
        peers_mutex.lockUncancelable(io_val);
        defer peers_mutex.unlock(io_val);
        if (slot.hello_done) return error.ProtocolError;
        slot.hello_done = true;
        slot.peer_id = pid;
        local_peer_id = pid;
        slot.state = .active;
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
    // ClientJoined を inbound 直列キューへ（pump が SYNC を送る）。mutex 保持中だが inbound は別 mutex。
    var joined: [8]u8 = undefined;
    std.mem.writeInt(u32, joined[0..4], pid, .little);
    std.mem.writeInt(u32, joined[4..8], slot.generation, .little);
    if (!inbound.enqueue(io_val, INTERNAL_CLIENT_JOINED, &joined, pid)) {
        return error.ProtocolError;
    }
}

/// テスト用リセット（shutdown + 状態クリア）。
pub fn resetForTest() void {
    shutdown();
    clearRouterMain();
    action_registry.resetForTest();
    shared_executor = null;
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
}

/// テスト用: slot の synced / snapshot_valid / join_snapshot_seq。
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

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

fn sleepMs(ms: u64) void {
    const req = std.posix.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&req, null);
}

fn waitPeers(n: usize, timeout_ms: u64) !void {
    var waited: u64 = 0;
    while (peerCount() < n) {
        if (waited >= timeout_ms) return error.Timeout;
        sleepMs(5);
        waited += 5;
    }
}

/// ClientJoined を処理して全 active slot を synced にする（空 SYNC 送出含む）。
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

/// raw client が HELLO の次に受ける空 SYNC を1件読む。
fn expectEmptySync(stream: net.Stream) !void {
    var rbuf: [256]u8 = undefined;
    var reader = stream.reader(io_val, &rbuf);
    var pbuf: [128]u8 = undefined;
    const frame = try decodeFrame(&reader.interface, &pbuf);
    try testing.expectEqual(@intFromEnum(FrameKind.sync), frame.kind);
    const parsed = try parseSyncPayload(frame.payload);
    try testing.expectEqual(@as(usize, 0), parsed.state.len);
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

test "netsync: codec 全 kind round-trip" {
    const kinds = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
    for (kinds) |k| {
        var obuf: [512]u8 = undefined;
        var w = Io.Writer.fixed(&obuf);
        const payload = "hello-payload";
        try encodeFrame(&w, k, payload);
        const encoded = w.buffered();

        var r = Io.Reader.fixed(encoded);
        var pbuf: [256]u8 = undefined;
        // SYNC も 4096 以下なら decodeFrame で読める
        const frame = try decodeFrame(&r, &pbuf);
        try testing.expectEqual(k, frame.kind);
        try testing.expectEqualStrings(payload, frame.payload);
    }
}

test "netsync: codec partial read 充足" {
    // 実 socket でヘッダと payload を分割送信し、decodeFrame が partial read を充足することを確認。
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
            // 3 byte（kind+len の途中）→ 残り
            var wbuf: [8]u8 = undefined;
            var writer = s.writer(io_val, &wbuf);
            writer.interface.writeAll(encoded[0..3]) catch return;
            writer.interface.flush() catch return;
            sleepMs(30);
            writer.interface.writeAll(encoded[3..]) catch return;
            writer.interface.flush() catch return;
            sleepMs(50); // reader が取り終わるまで維持
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

test "netsync: codec 未知 kind は上限内なら decode 可・maxPayload は 4096" {
    try testing.expectEqual(@as(usize, MAX_ACTION_FRAME_BYTES), maxPayloadForKind(0x99));
    try testing.expectEqual(@as(usize, MAX_SYNC_BYTES), maxPayloadForKind(0x04));
    try testing.expectEqual(@as(usize, MAX_ACTION_FRAME_BYTES), maxPayloadForKind(0x01));
}

test "netsync: codec len 超過は PayloadTooLarge" {
    var obuf: [32]u8 = undefined;
    var w = Io.Writer.fixed(&obuf);
    try w.writeByte(0x02);
    try w.writeInt(u32, 5000, .little); // > 4096
    // payload は書かない
    var r = Io.Reader.fixed(w.buffered());
    var pbuf: [MAX_ACTION_FRAME_BYTES]u8 = undefined;
    try testing.expectError(error.PayloadTooLarge, decodeFrame(&r, &pbuf));
}

test "netsync: codec SYNC 大容量は discardPayload で読み捨て" {
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

test "netsync: HELLO parse フィールド不足・不正 actor_kind・label 超過・制御文字" {
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

test "netsync: loopback HELLO 握手成功" {
    // 同一プロセスは host/client どちらか一方の role のみ（module singleton）。
    // client 役の initClient 結合は 2 プロセス E2E（62.3.2）へ。ここでは raw connect で
    // host 側 HELLO 採番・peer テーブルを検証する。
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
    try testing.expectEqual(@as(u32, 0), localPeerId()); // host 自身
}

test "netsync: 複数 client MAX_PEERS まで HELLO" {
    resetForTest();
    defer resetForTest();
    initHost(0);
    const port = listeningPort().?;
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };

    // 順次接続（同時 initClient は module 単一 client_slot のため不可）。
    // host 側スロットに MAX_PEERS 本載せるには、client を別プロセス相当で繋ぐ必要がある。
    // ここでは raw connect + HELLO を手書きしてスロットを埋める。
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

        // 応答 HELLO を読む
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

test "netsync: MAX_PEERS 超過は切断" {
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

    // 超過接続: accept 後即 close される。書き込み/読みで失敗するはず。
    const extra = try addr.connect(io_val, .{ .mode = .stream });
    streams[n] = extra;
    n += 1;
    sleepMs(50);
    // peerCount は増えない
    try testing.expectEqual(@as(usize, MAX_PEERS), peerCount());
}

test "netsync: 1 client 切断後の slot 再利用" {
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
    // close 後スロット解放待ち
    var waited: u64 = 0;
    while (peerCount() != 0) {
        if (waited >= 3000) return error.Timeout;
        sleepMs(10);
        waited += 10;
    }

    // 再利用
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

test "netsync: shutdown 後は connection refused" {
    resetForTest();
    initHost(0);
    const port = listeningPort().?;
    shutdown();
    ensureIo();
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    try testing.expectError(error.ConnectionRefused, addr.connect(io_val, .{ .mode = .stream }));
}

test "netsync: host 未起動 fail-soft" {
    resetForTest();
    defer resetForTest();
    ensureIo();
    // 未使用高位 port
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(1) }; // usually refused
    initClient(addr);
    try testing.expect(!isEnabled());
    try testing.expect(!isClient());
}

test "netsync: shutdown 二重呼び出し安全" {
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
        const frame = try decodeFrame(&reader.interface, &pbuf);
        try testing.expectEqual(@intFromEnum(FrameKind.commit), frame.kind);
        try testing.expectEqualStrings("seq-test", frame.payload);
    }
}

test "netsync: inbound 満杯で切断" {
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
    // ClientJoined を処理して inbound を空けてから PROPOSE を詰める
    try pumpUntilAllSynced(2000);
    try expectEmptySync(s);

    // pump せず INBOUND_CAP+1 個の PROPOSE を送る
    var n: usize = 0;
    while (n < INBOUND_CAP + 8) : (n += 1) {
        encodeFrame(&writer.interface, @intFromEnum(FrameKind.propose), "x") catch break;
        writer.interface.flush() catch break;
    }

    // 切断されるまで待つ（peer テーブルから消える + 相手 read が EOF）
    var waited: u64 = 0;
    while (peerCount() != 0) {
        if (waited >= 3000) return error.Timeout;
        sleepMs(10);
        waited += 10;
    }
    // 切断後の read は EOF / エラー
    try testing.expect(std.meta.isError(reader.interface.takeByte()));
}

test "netsync: HELLO 前の SYNC は切断（読み捨て継続しない）" {
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
    // HELLO 前に SYNC → protocol error 切断（その後 HELLO しても active 化しない）
    try encodeFrame(&writer.interface, @intFromEnum(FrameKind.sync), "sync-early");
    try writer.interface.flush();
    try encodeFrame(&writer.interface, @intFromEnum(FrameKind.hello), "client 1 human late");
    try writer.interface.flush();
    sleepMs(100);
    try testing.expectEqual(@as(usize, 0), peerCount());
}

test "netsync: HELLO 前の非 HELLO / duplicate / version 不一致は切断" {
    resetForTest();
    defer resetForTest();
    initHost(0);
    const port = listeningPort().?;
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    ensureIo();

    // 非 HELLO 先送り
    {
        const s = try addr.connect(io_val, .{ .mode = .stream });
        defer s.close(io_val);
        var wbuf: [128]u8 = undefined;
        var writer = s.writer(io_val, &wbuf);
        try encodeFrame(&writer.interface, @intFromEnum(FrameKind.propose), "nope");
        try writer.interface.flush();
        sleepMs(50);
    }

    // version 不一致
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

test "netsync: clientSend outbound 満杯で fail-soft" {
    // 同一プロセスで host 役は使えないので、dumb host スレッドを立てて client 役で接続する。
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
            // 以降読まない（TCP 窓を詰まらせる）。client 切断で EOF になるまで待つ。
            while (true) {
                _ = reader.interface.takeByte() catch break;
            }
        }
    };
    const ht = try std.Thread.spawn(.{}, DumbHost.run, .{&srv});
    defer {
        // client 側 shutdown 後に host が終わる。listen を閉じてから join。
        resetForTest();
        srv.deinit(io_val);
        ht.join();
    }

    const caddr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    initClientAs(caddr, .human, "flood-client");
    try waitClientActive(2000);
    try testing.expect(isEnabled());

    // 大きな payload を連打。peer が読まないため writer が TCP で詰まり outbound が満杯になる。
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
// TASK-62.3.2 semantic tests
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
    ensureIo();
    const s = try addr.connect(io_val, .{ .mode = .stream });
    var wbuf: [256]u8 = undefined;
    var writer = s.writer(io_val, &wbuf);
    var hbuf: [128]u8 = undefined;
    const hello = try std.fmt.bufPrint(&hbuf, "client {d} human {s}", .{ PROTOCOL_VERSION, label });
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

test "netsync: router host 5 policy 分岐" {
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
    try testing.expectEqual(@as(u64, 1), wireSeq()); // local_only は seq 消費しない

    try testing.expectError(error.RejectedWhileSynced, action_registry.routeLocalAction("h_reject", "", &buf));
    try testing.expectError(error.RejectedWhileSynced, action_registry.routeLocalAction("h_undo", "", &buf));
    try testing.expectError(error.RejectedWhileSynced, action_registry.routeLocalAction("h_redo", "", &buf));
}

test "netsync: router client 5 policy 分岐" {
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
            // PROPOSE を1件読んで捨てる（client relay 用）
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

    var buf: [128]u8 = undefined;
    const pr = try action_registry.routeLocalAction("c_relay", "x", &buf);
    try testing.expectEqualStrings("proposed 1", pr);
    try testing.expectEqual(@as(u32, 0), ctx.calls); // ローカル適用なし

    const loc = try action_registry.routeLocalAction("c_local", "y", &buf);
    try testing.expectEqualStrings("ok:y", loc);
    try testing.expectEqual(@as(u32, 1), ctx.calls);

    try testing.expectError(error.RejectedWhileSynced, action_registry.routeLocalAction("c_reject", "", &buf));
    try testing.expectError(error.RejectedWhileSynced, action_registry.routeLocalAction("c_undo", "", &buf));
    try testing.expectError(error.RejectedWhileSynced, action_registry.routeLocalAction("c_redo", "", &buf));
}

test "netsync: commitAndBroadcast seq 単調増加と COMMIT origin_peer=0" {
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

test "netsync: host PROPOSE 再検証 REJECT（non-relay・未知）" {
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

    // host が読むまで待つ
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

test "netsync: PROPOSE→COMMIT round-trip（no_record で CommandRecord 増えない）" {
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
    // dispatch fallback 経路も動くよう register（executor が優先）
    registerSem("stroke", &ctx, .relay);
    // executor 経由にするため dispatcher を action 名で呼ぶ — applyRemoteNoRecord は executor を使う
    // register の run は host ローカル commitAndBroadcast 用。PROPOSE 適用は executor。

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
    try testing.expectEqual(before, log.filled); // no_record
    try testing.expectEqual(@as(u64, 1), wireSeq());

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

test "netsync: REJECT 受信で last_rejected_proposal 保存" {
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
            // 空 SYNC で awaiting_sync を解除してから REJECT
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
    // SYNC 適用 → awaiting_sync 解除
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

test "netsync: proposal_id 単調増加" {
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
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("proposed 1", try proposeToHost("stroke", "a", &buf));
    try testing.expectEqualStrings("proposed 2", try proposeToHost("stroke", "b", &buf));
}

test "netsync: local_only seq 消費後も remote no_record 適用成功" {
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
            // local_only が終わるのを待ってから COMMIT を送る
            sleepMs(50);
            const commit = formatCommitPayload(&pbuf, 99, 0, "stroke", "remote") catch return;
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

    // 空 SYNC でゲート解除
    var waited_sync: u64 = 0;
    while (testAwaitingSync() and waited_sync < 2000) : (waited_sync += 5) {
        pump();
        sleepMs(5);
    }
    try testing.expect(!testAwaitingSync());

    // local_only を executor 経由で記録（seq 消費）
    var buf: [128]u8 = undefined;
    _ = try exec.executeAction("save", "/tmp/x", .{ .actor = .local_user, .record_policy = .record }, &buf);
    try testing.expectEqual(@as(u32, 1), log.filled);
    const next_after_local = log.next_seq;

    var waited: u64 = 0;
    while (inboundLen() < 1 and waited < 2000) : (waited += 5) sleepMs(5);
    pump();
    // no_record なので filled は増えず、Stale にもならない
    try testing.expectEqual(@as(u32, 1), log.filled);
    try testing.expectEqual(next_after_local, log.next_seq);
    try testing.expect(exec_ctx.calls >= 2); // save + remote stroke
}

test "netsync: fail-soft 後 pump で router 解除され通常ローカル動作" {
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
            // client が active になるまで維持してから切断
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

    close_gate.store(true, .seq_cst); // host が接続を閉じる
    var waited: u64 = 0;
    while (isEnabled() and waited < 3000) : (waited += 10) sleepMs(10);
    try testing.expect(!isEnabled());

    pump(); // router_clear_pending → setRouter(null)
    var buf: [64]u8 = undefined;
    const out = try action_registry.routeLocalAction("stroke", "z", &buf);
    try testing.expectEqualStrings("ok:z", out);
    try testing.expectEqual(@as(u32, 1), ctx.calls);
}

test "netsync: shutdown 後 routeLocalAction は dispatch 等価" {
    resetForTest();
    defer resetForTest();
    var ctx: SemCtx = .{};
    registerSem("stroke", &ctx, .relay);
    initHost(0);
    try testing.expect(isHost());
    shutdown();
    try testing.expect(!isEnabled());
    // shutdown は setRouter(null)。register は残る（resetForTest 前）
    action_registry.setEnabled(true);
    var buf: [64]u8 = undefined;
    const out = try action_registry.routeLocalAction("stroke", "s", &buf);
    try testing.expectEqualStrings("ok:s", out);
}

test "netsync: env 未設定パススルー（pump/isEnabled）" {
    resetForTest();
    defer resetForTest();
    try testing.expect(!isEnabled());
    pump(); // no-op
    try testing.expectEqual(@as(usize, 0), inboundLen());
}

test "netsync: デフォルト識別子 HELLO は parseClientHello 受理（initClient 経路）" {
    resetForTest();
    defer resetForTest();
    // initClient が渡すのと同じスライスで HELLO を組み立てる（宣言時 "client" 初期化の回帰）。
    try testing.expectEqual(@as(usize, default_client_label.len), client_label_len);
    try testing.expectEqualStrings(default_client_label, client_label_buf[0..client_label_len]);
    var buf: [256]u8 = undefined;
    const payload = try formatClientHello(&buf, client_actor_kind, client_label_buf[0..client_label_len]);
    const parsed = try parseClientHello(payload);
    try testing.expectEqual(ActorKind.human, parsed.kind);
    try testing.expectEqualStrings("client", parsed.label);
    for (parsed.label) |c| try testing.expect(c >= 0x20);
}

test "netsync: 未初期化相当 label でも defaultClientLabel 後は HELLO 受理" {
    resetForTest();
    defer resetForTest();
    // E2E で観測したバグ状態: len=6 だが buf が NUL 埋め
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
// TASK-62.3.3 StateSync / SYNC tests
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

test "netsync: StateSync register/reset と無効時も安全" {
    resetForTest();
    defer resetForTest();
    var ctx: SyncCtx = .{};
    registerStateSync(.{ .ctx = &ctx, .export_fn = syncExport, .import_fn = syncImport });
    try testing.expect(state_sync != null);
    resetForTest();
    try testing.expect(state_sync == null);
    // 無効時も register 可
    registerStateSync(.{ .ctx = &ctx, .export_fn = syncExport, .import_fn = syncImport });
    try testing.expect(state_sync != null);
}

test "netsync: join 後の非 HELLO 先頭 frame は SYNC（空・snapshot_valid=false）" {
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

test "netsync: synced ゲート（SYNC 前 COMMIT 不達・SYNC 後は届く）" {
    resetForTest();
    defer resetForTest();
    var ctx: SemCtx = .{};
    registerSem("stroke", &ctx, .relay);
    initHost(0);
    const port = listeningPort().?;
    var stream = try rawHelloConnect(net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) }, "gate");
    defer stream.close(io_val);
    try waitPeers(1, 2000);

    // ClientJoined 未処理 = 未 synced → broadcast されない
    var buf: [64]u8 = undefined;
    _ = try commitAndBroadcast("stroke", "pre", &buf);

    try pumpUntilAllSynced(2000);
    try expectEmptySync(stream); // SYNC のみ（pre COMMIT は無い）

    _ = try commitAndBroadcast("stroke", "post", &buf);
    var rbuf: [256]u8 = undefined;
    var reader = stream.reader(io_val, &rbuf);
    var pbuf: [128]u8 = undefined;
    const f = try decodeFrame(&reader.interface, &pbuf);
    try testing.expectEqual(@intFromEnum(FrameKind.commit), f.kind);
    const c = try parseCommitPayload(f.payload);
    try testing.expectEqualStrings("post", c.args);
}

test "netsync: export 登録時 SYNC に state が載り snapshot_valid" {
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
    var rbuf: [256]u8 = undefined;
    var reader = stream.reader(io_val, &rbuf);
    var pbuf: [128]u8 = undefined;
    const f = try decodeFrame(&reader.interface, &pbuf);
    try testing.expectEqual(@intFromEnum(FrameKind.sync), f.kind);
    const p = try parseSyncPayload(f.payload);
    try testing.expectEqualStrings("DOC42", p.state);
    const info = testSlotSyncInfo(1).?;
    try testing.expect(info.snapshot_valid);
}

test "netsync: export 0 byte は切断" {
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

test "netsync: client SYNC import と awaiting_sync 中 COMMIT 保留" {
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
            // COMMIT を先に送り、その後大きな SYNC（awaiting 中は COMMIT 保留）
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

    // COMMIT は inbound に残るが awaiting のため適用されない
    var waited: u64 = 0;
    while (inboundLen() < 1 and waited < 2000) : (waited += 5) sleepMs(5);
    pump(); // SYNC 未着なら dequeue しない。SYNC 着なら import→その後も同 pump では dequeue しない（awaiting 解除後の次 pump）
    // SYNC 待ち
    waited = 0;
    while (testAwaitingSync() and waited < 3000) : (waited += 5) {
        pump();
        sleepMs(5);
    }
    try testing.expect(!testAwaitingSync());
    try testing.expectEqual(@as(u32, 1), sctx.import_calls);
    try testing.expectEqualStrings("BIGSTATE_OVER_INLINE", sctx.last_import[0..sctx.last_import_len]);
    try testing.expectEqual(@as(u32, 0), actx.calls); // COMMIT まだ

    pump(); // 保留 COMMIT 適用
    try testing.expectEqual(@as(u32, 1), actx.calls);
}

test "netsync: import 失敗は fail-soft（保留 COMMIT 不適用）" {
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

test "netsync: stale ClientJoined は無視" {
    resetForTest();
    defer resetForTest();
    initHost(0);
    // 直接 stale マーカーを積む
    var joined: [8]u8 = undefined;
    std.mem.writeInt(u32, joined[0..4], 99, .little);
    std.mem.writeInt(u32, joined[4..8], 1, .little);
    try testing.expect(inbound.enqueue(io_val, INTERNAL_CLIENT_JOINED, &joined, 99));
    pump(); // 無視して落ちない
    try testing.expectEqual(@as(usize, 0), peerCount());
}

test "netsync: big-entry enqueue 失敗時は呼び出し元が解放（切断）" {
    resetForTest();
    defer resetForTest();
    // outbound を満杯にして enqueueBig 失敗経路を踏む
    initHost(0);
    const port = listeningPort().?;
    var stream = try rawHelloConnect(net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) }, "full");
    defer stream.close(io_val);
    try waitPeers(1, 2000);

    peers_mutex.lockUncancelable(io_val);
    const slot = &slots[0];
    // ClientJoined 前に outbound を詰め、writer の drain で空きが出ないよう close して enqueueBig 失敗を確定させる
    var i: usize = 0;
    while (i < OUTBOUND_CAP) : (i += 1) {
        _ = slot.outbound.enqueue(io_val, 0x03, "pad");
    }
    slot.outbound.close(io_val);
    peers_mutex.unlock(io_val);

    pump(); // ClientJoined → enqueueBig 失敗 → 呼び出し元解放 + 切断
    var waited: u64 = 0;
    while (peerCount() != 0 and waited < 3000) : (waited += 10) sleepMs(10);
    try testing.expectEqual(@as(usize, 0), peerCount());
}

test "netsync: big-entry 解放（dequeue 後・reset 未送出・enqueue 失敗呼び出し元）" {
    resetForTest();
    defer resetForTest();
    ensureIo();
    var q: OutboundQueue = .{};

    // 送出後相当: dequeue 所有権移転 → free
    {
        const buf = try gpa.alloc(u8, 64);
        @memset(buf, 0xAB);
        try testing.expect(q.enqueueBig(io_val, 0x04, buf));
        var entry: OutboundEntry = .{ .inline_frame = .{} };
        try testing.expect(q.dequeueWait(io_val, &entry) != null);
        entry.free();
    }

    // shutdown/切断相当: reset が未送出 big を解放
    {
        const buf = try gpa.alloc(u8, 32);
        @memset(buf, 0xCD);
        try testing.expect(q.enqueueBig(io_val, 0x04, buf));
        q.reset(io_val);
        try testing.expectEqual(@as(usize, 0), q.count);
    }

    // enqueue 失敗時は呼び出し元が解放（満杯）
    {
        var i: usize = 0;
        while (i < OUTBOUND_CAP) : (i += 1) {
            try testing.expect(q.enqueue(io_val, 0x03, "x"));
        }
        const orphan = try gpa.alloc(u8, 16);
        try testing.expect(!q.enqueueBig(io_val, 0x04, orphan));
        gpa.free(orphan); // 呼び出し元解放
        q.reset(io_val);
    }

    // closed でも enqueueBig 失敗 → 呼び出し元解放
    {
        q.close(io_val);
        const orphan = try gpa.alloc(u8, 8);
        try testing.expect(!q.enqueueBig(io_val, 0x04, orphan));
        gpa.free(orphan);
        q.reset(io_val);
    }
}

test "netsync: writer encode/flush 失敗時も big-entry 解放" {
    resetForTest();
    defer resetForTest();
    initHost(0);
    const port = listeningPort().?;
    var stream = try rawHelloConnect(net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) }, "wfail");
    try waitPeers(1, 2000);
    try pumpUntilAllSynced(2000);
    try expectEmptySync(stream);

    // 大きな big-entry を積み、対向を閉じて write/flush 失敗 → writer が entry.free()
    peers_mutex.lockUncancelable(io_val);
    const big = try gpa.alloc(u8, 256 * 1024);
    @memset(big, 0xEF);
    try testing.expect(slots[0].outbound.enqueueBig(io_val, @intFromEnum(FrameKind.sync), big));
    peers_mutex.unlock(io_val);

    stream.close(io_val);

    var waited: u64 = 0;
    while (peerCount() != 0 and waited < 5000) : (waited += 10) sleepMs(10);
    try testing.expectEqual(@as(usize, 0), peerCount());
    peers_mutex.lockUncancelable(io_val);
    defer peers_mutex.unlock(io_val);
    try testing.expectEqual(@as(usize, 0), slots[0].outbound.count);
    try testing.expect(slots[0].state == .empty);
}

test "netsync: slot 再利用時に前接続の未送出 big-entry が残らない" {
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
    // writer を止めて未送出のまま残す（reset/cleanup 経路の解放を検証）
    slots[0].outbound.close(io_val);
    peers_mutex.unlock(io_val);

    stream.close(io_val);
    var waited: u64 = 0;
    while (peerCount() != 0 and waited < 5000) : (waited += 10) sleepMs(10);
    try testing.expectEqual(@as(usize, 0), peerCount());

    var stream2 = try rawHelloConnect(addr, "reuse2");
    defer stream2.close(io_val);
    try waitPeers(1, 2000);

    peers_mutex.lockUncancelable(io_val);
    defer peers_mutex.unlock(io_val);
    try testing.expect(slots[0].state == .active or slots[0].state == .hello_pending);
    try testing.expect(slots[0].generation != gen0);
    try testing.expectEqual(@as(usize, 0), slots[0].outbound.count);
}

test "netsync: shutdown 中の未送出 big-entry 解放と writer join" {
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
    // 未送出を残すため writer を起こして終了させ、queue に entry を残す
    slots[0].outbound.close(io_val);
    peers_mutex.unlock(io_val);
    sleepMs(20); // writer が dequeueWait から抜けるのを待つ

    shutdown();
    try testing.expect(!isEnabled());
    peers_mutex.lockUncancelable(io_val);
    defer peers_mutex.unlock(io_val);
    try testing.expectEqual(@as(usize, 0), slots[0].outbound.count);
    try testing.expect(slots[0].writer_thread == null);
    try testing.expect(slots[0].state == .empty);
}

test "netsync: gatherStats 無効時は既定値" {
    resetForTest();
    defer resetForTest();
    const st = gatherStats();
    try testing.expectEqual(Role.disabled, st.role);
    try testing.expectEqual(@as(usize, 0), st.peers);
    try testing.expectEqual(@as(u32, 0), st.peer_id);
    try testing.expectEqual(@as(u64, 0), st.last_seq);
    try testing.expectEqual(@as(usize, 0), st.pending);
    try testing.expect(!st.awaiting_sync);
    try testing.expectEqual(@as(u32, 0), st.last_reject);
}

test "netsync: gatherStats host 有効時 peers・pending" {
    resetForTest();
    defer resetForTest();
    initHost(0);
    const port = listeningPort().?;
    var stream = try rawHelloConnect(net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) }, "gs");
    defer stream.close(io_val);
    try waitPeers(1, 2000);

    // ClientJoined 未 pump → pending>=1
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

test "netsync: gatherStats client awaiting_sync 遷移と last_applied_seq" {
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

test "netsync: digest 整形・reject_reason 正規化と切り詰め" {
    resetForTest();
    defer resetForTest();

    var buf: [512]u8 = undefined;
    const disabled = formatDigest(&buf);
    try testing.expect(std.mem.startsWith(u8, disabled, "role=disabled"));
    try testing.expect(std.mem.indexOf(u8, disabled, "last_reject=none") != null);
    try testing.expect(std.mem.indexOf(u8, disabled, "reject_reason=none") != null);

    // reason 正規化（単体）
    var tok: [64]u8 = undefined;
    const s1 = sanitizeRejectReasonToken(&tok, "a b\tc\nd\r");
    try testing.expectEqualStrings("a_b_c_d_", s1);
    const long = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdefEXTRA";
    const s2 = sanitizeRejectReasonToken(&tok, long);
    try testing.expectEqual(@as(usize, 64), s2.len);
    try testing.expect(std.mem.eql(u8, s2, long[0..64]));

    // REJECT 後の digest
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
