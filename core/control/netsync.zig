//! netsync transport 基盤（TASK-62.3.1）: 持続 TCP 接続・HELLO 握手・フレーム codec・キュー。
//!
//! PROPOSE/COMMIT の semantic routing / action_registry router 登録 / platform 配線は 62.3.2。
//! 本モジュールは std のみ（ADR-007 core 層。harness/libs 非依存）。
//!
//! ## ホットパス宣言
//! 全コードは「イベント時のみ」（接続確立・フレーム受信・HELLO 処理）。フレーム毎（全画素）/
//! RT（毎サンプル）経路には一切触れない。reader/writer/acceptor thread はブロッキング socket I/O
//! 専用で app 状態に触れない（app 状態に触れるのは main thread の pump のみ＝62.3.2 以降）。

const std = @import("std");
const builtin = @import("builtin");
const net = std.Io.net;
const Io = std.Io;

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

const Role = enum { disabled, host, client };
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

// ============================================================================
// Queues
// ============================================================================

const QueueSlot = struct {
    kind: u8 = 0,
    len: u32 = 0,
    data: [MAX_ACTION_FRAME_BYTES]u8 = undefined,
};

const InboundQueue = struct {
    mutex: Io.Mutex = .init,
    slots: [INBOUND_CAP]QueueSlot = undefined,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,

    fn enqueue(self: *InboundQueue, io: Io, kind: u8, payload: []const u8) bool {
        if (payload.len > MAX_ACTION_FRAME_BYTES) return false;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.count >= INBOUND_CAP) return false;
        const s = &self.slots[self.tail];
        s.kind = kind;
        s.len = @intCast(payload.len);
        if (payload.len > 0) @memcpy(s.data[0..payload.len], payload);
        self.tail = (self.tail + 1) % INBOUND_CAP;
        self.count += 1;
        return true;
    }

    fn dequeue(self: *InboundQueue, io: Io, out_kind: *u8, out_buf: []u8) ?usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.count == 0) return null;
        const s = &self.slots[self.head];
        out_kind.* = s.kind;
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
    slots: [OUTBOUND_CAP]QueueSlot = undefined,
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
        const s = &self.slots[self.tail];
        s.kind = kind;
        s.len = @intCast(payload.len);
        if (payload.len > 0) @memcpy(s.data[0..payload.len], payload);
        self.tail = (self.tail + 1) % OUTBOUND_CAP;
        self.count += 1;
        self.cond.signal(io);
        return true;
    }

    /// writer 用。closed かつ空なら null。待機して frame を返す。
    fn dequeueWait(self: *OutboundQueue, io: Io, out: *QueueSlot) ?void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (self.count == 0 and !self.closed) {
            self.cond.waitUncancelable(io, &self.mutex);
        }
        if (self.count == 0) return null; // closed
        out.* = self.slots[self.head];
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

    fn reset(self: *OutboundQueue, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.head = 0;
        self.tail = 0;
        self.count = 0;
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
    reader_thread: ?std.Thread = null,
    writer_thread: ?std.Thread = null,
    outbound: OutboundQueue = .{},
    /// host slots 配列内 index。client は 0。
    slot_index: usize = 0,
    is_client_conn: bool = false,
};

// ============================================================================
// Module state
// ============================================================================
//
// ## 同期規約（peers_mutex）
// 次のフィールドの読み書きはすべて `peers_mutex` 下で行う（イベント時のみの経路）:
//   role / started / local_peer_id / next_peer_id /
//   slots[*].state および slot の peer メタ（peer_id/kind/label/hello_done/socket_open）/
//   client_slot の同種フィールド
// `stop_flag` のみ atomic。`have_server` / acceptor_thread は main（init/shutdown）専有。
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
var client_label_buf: [MAX_LABEL_LEN]u8 = undefined;
var client_label_len: usize = 6; // "client"

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
    const d = "client";
    @memcpy(client_label_buf[0..d.len], d);
    client_label_len = d.len;
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
    std.debug.print("[netsync] host 有効: 127.0.0.1:{d}\n", .{server.socket.address.getPort()});
}

pub fn initClient(addr: net.IpAddress) void {
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
    const n = @min(label.len, MAX_LABEL_LEN);
    if (n > 0) @memcpy(client_slot.label_buf[0..n], label[0..n]);
    client_slot.label_len = n;
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

    // client HELLO を outbound へ
    var hbuf: [MAX_ACTION_FRAME_BYTES]u8 = undefined;
    const hello = formatClientHello(&hbuf, kind, label) catch {
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
    std.debug.print("[netsync] client 接続中\n", .{});
}

pub fn pump() void {
    if (!isEnabled()) return;
    var kind: u8 = 0;
    var buf: [MAX_ACTION_FRAME_BYTES]u8 = undefined;
    // 62.3.1: semantic 適用はしない。inbound を drain するだけ。
    while (inbound.dequeue(io_val, &kind, &buf)) |_| {}
}

/// テスト用: inbound を drain せず 1 件 peek/dequeue。
pub fn dequeueInbound(out_kind: *u8, out_buf: []u8) ?usize {
    if (!isEnabled()) return null;
    return inbound.dequeue(io_val, out_kind, out_buf);
}

/// active な全接続の outbound へ fan-out。
pub fn broadcast(kind: u8, payload: []const u8) void {
    if (!io_inited) return;
    peers_mutex.lockUncancelable(io_val);
    defer peers_mutex.unlock(io_val);
    if (!started or role != .host) return;
    for (&slots) |*s| {
        if (s.state != .active) continue;
        if (!s.outbound.enqueue(io_val, kind, payload)) {
            // outbound 満杯 → 当該接続切断（host）
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

    if (have_server) {
        server.socket.close(io_val);
        have_server = false;
    }
    if (acceptor_thread) |t| {
        t.join();
        acceptor_thread = null;
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
    peers_mutex.unlock(io_val);
}

fn requestCloseSlot(s: *ConnSlot) void {
    peers_mutex.lockUncancelable(io_val);
    defer peers_mutex.unlock(io_val);
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
                    s.* = .{
                        .state = .hello_pending,
                        .stream = stream,
                        .socket_open = true,
                        .slot_index = i,
                        .is_client_conn = false,
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
    var frame: QueueSlot = undefined;
    while (true) {
        if (slot.outbound.dequeueWait(io_val, &frame) == null) break;
        encodeFrame(&writer.interface, frame.kind, frame.data[0..frame.len]) catch {
            // 送信失敗 → reader を起こして共通 cleanup へ合流
            requestCloseSlot(slot);
            break;
        };
        writer.interface.flush() catch {
            requestCloseSlot(slot);
            break;
        };
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
            // payload は読まず切断（接続 close で残りは破棄）
            break;
        }

        const unprocessed = (kind == @intFromEnum(FrameKind.sync)) or !isKnownKind(kind);
        if (unprocessed) {
            if (!isKnownKind(kind)) {
                std.debug.print("[netsync] 未知 frame kind=0x{x:0>2} len={d} — 読み捨て継続\n", .{ kind, len });
            }
            discardPayload(&reader.interface, len) catch break;
            continue;
        }

        if (len > payload_buf.len) break;
        if (len > 0) reader.interface.readSliceAll(payload_buf[0..len]) catch break;
        const payload = payload_buf[0..len];

        if (!slot.hello_done) {
            // 上で HELLO 以外は弾済み
            handleHello(slot, payload) catch break;
            continue;
        }

        if (kind == @intFromEnum(FrameKind.hello)) break; // duplicate HELLO

        if (!inbound.enqueue(io_val, kind, payload)) {
            std.debug.print("[netsync] inbound 満杯 — 接続を切断します\n", .{});
            break;
        }
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
    slot.peer_id = 0;
    slot.label_len = 0;
    slot.reader_thread = null;
    // client 切断後は同 mutex 下で netsync を fail-soft 無効化。
    if (was_client) {
        role = .disabled;
        started = false;
        local_peer_id = 0;
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

    var hbuf: [64]u8 = undefined;
    const resp = formatHostHello(&hbuf, pid) catch return error.ProtocolError;
    if (!slot.outbound.enqueue(io_val, @intFromEnum(FrameKind.hello), resp)) {
        return error.ProtocolError;
    }
}

/// テスト用リセット（shutdown + 状態クリア）。
pub fn resetForTest() void {
    shutdown();
    defaultClientLabel();
    stop_flag.store(false, .seq_cst);
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
